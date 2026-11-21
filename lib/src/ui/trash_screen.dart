import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../data/models.dart';
import '../data/repo.dart';

/// The Trash: deleted tasks and projects, newest first, with a way back.
///
/// It reads the local replica, so it opens offline. Restoring is a field write
/// (it queues an op and reaches the other devices); purging is the one action
/// that needs the server, because only the server can remove the history.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.state});

  final AppState state;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<Task> _tasks = const [];
  List<Project> _projects = const [];
  Map<String, String> _projectNames = const {};
  bool _loading = true;
  bool _busy = false;

  Repo? get _repo => widget.state.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = _repo;
    if (repo == null) return;
    final tasks = await repo.trashedTasks();
    final projects = await repo.trashedProjects();
    final all = await repo.allProjects();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _projects = projects;
      _projectNames = {for (final p in all) p.id: p.name};
      _loading = false;
    });
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _when(Map<String, Object?> raw) {
    final value = raw['deleted_at'];
    if (value is! num) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal();
    return DateFormat.yMMMd().add_Hm().format(at);
  }

  Future<void> _restoreTask(Task task) async {
    setState(() => _busy = true);
    try {
      await _repo?.restoreTask(task);
      _say('Task restored');
      await _load();
    } on Object catch (e) {
      _say(_explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreProject(Project project) async {
    setState(() => _busy = true);
    try {
      await _repo?.restoreProject(project);
      _say('Project restored with its tasks');
      await _load();
    } on Object catch (e) {
      _say(_explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    return answer == true;
  }

  Future<void> _purgeTask(Task task) async {
    if (!await _confirm('Delete this task forever?',
        '"${task.title}" and the subtasks deleted with it will leave the server. This cannot be undone.')) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _repo?.purgeTask(task);
      _say('Deleted forever');
      await _load();
    } on Object catch (e) {
      _say(_explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeProject(Project project) async {
    if (!await _confirm('Delete this project forever?',
        '"${project.name}" and every task in it will leave the server. This cannot be undone.')) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _repo?.purgeProject(project);
      _say('Deleted forever');
      await _load();
    } on Object catch (e) {
      _say(_explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _empty() async {
    if (!await _confirm(
        'Empty the Trash?', 'Every deleted task and project will leave the server. This cannot be undone.')) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _repo?.emptyTrash();
      _say('Trash emptied');
      await _load();
    } on Object catch (e) {
      _say(_explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _explain(Object error) {
    if (error is ApiException) {
      return switch (error.code) {
        'network' || 'timeout' => 'Connect to the server to delete permanently.',
        'not_deleted' => 'This item is no longer in the Trash.',
        'not_found' => 'This item was already deleted on the server.',
        'forbidden' => 'Your role on this project does not allow deleting it.',
        'mfa_enrolment_required' => 'Finish setting up two-factor authentication first.',
        _ => error.message,
      };
    }
    return 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _tasks.length + _projects.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          IconButton(
            tooltip: 'Empty the Trash',
            onPressed: _busy || total == 0 ? null : _empty,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : total == 0
              ? _emptyState(theme)
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    if (_projects.isNotEmpty) ...[
                      _Header('Projects', count: _projects.length),
                      for (final project in _projects)
                        _Row(
                          icon: Icons.folder_outlined,
                          color: theme.colorScheme.primary,
                          title: project.name,
                          subtitle: 'Deleted ${_when(project.raw)}',
                          busy: _busy,
                          onRestore: () => _restoreProject(project),
                          onPurge: () => _purgeProject(project),
                        ),
                    ],
                    if (_tasks.isNotEmpty) ...[
                      _Header('Tasks', count: _tasks.length),
                      for (final task in _tasks)
                        _Row(
                          icon: Icons.check_circle_outline,
                          color: theme.colorScheme.onSurfaceVariant,
                          title: task.title.isEmpty ? 'Untitled task' : task.title,
                          subtitle: [
                            'Deleted ${_when(task.raw)}',
                            if (task.projectId != null && _projectNames[task.projectId] != null)
                              _projectNames[task.projectId]!,
                          ].join(' · '),
                          busy: _busy,
                          onRestore: () => _restoreTask(task),
                          onPurge: () => _purgeTask(task),
                        ),
                    ],
                  ],
                ),
      bottomNavigationBar: total == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  'Deleted items keep their history until you delete them forever.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
    );
  }

  Widget _emptyState(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('The Trash is empty', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Deleted tasks and projects wait here until you restore them or delete them forever.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header(this.label, {required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        '$label ($count)',
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.1,
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.onRestore,
    required this.onPurge,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: !busy,
      leading: Icon(icon, color: color),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        tooltip: 'Trash actions',
        enabled: !busy,
        onSelected: (value) => value == 'restore' ? onRestore() : onPurge(),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'restore', child: Text('Restore')),
          PopupMenuItem(value: 'purge', child: Text('Delete forever')),
        ],
      ),
    );
  }
}
