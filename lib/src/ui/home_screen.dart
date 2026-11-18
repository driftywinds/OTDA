import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/views.dart';
import 'new_task_sheet.dart';
import 'task_sheet.dart';

enum TaskView { today, inbox, anytime, someday }

/// The task list over the local replica: readable and editable with no network.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Task> _tasks = const [];
  Map<String, String> _projectNames = const {};
  TaskView _view = TaskView.today;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final tasks = await repo.tasks();
    final projects = await repo.projects();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _projectNames = {
        for (final p in projects)
          if (!p.isDeleted) p.id: p.name,
      };
      _loading = false;
    });
  }

  String get _today {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  List<Task> get _visible {
    final today = _today;
    final byId = {for (final t in _tasks) t.id: t.raw};
    switch (_view) {
      case TaskView.today:
        return _tasks.where((t) => inToday(t.raw, today)).toList()
          ..sort((a, b) {
            final ak = '${a.dueDate ?? a.deadline ?? '9999'}${a.dueTime ?? '99:99'}';
            final bk = '${b.dueDate ?? b.deadline ?? '9999'}${b.dueTime ?? '99:99'}';
            return ak.compareTo(bk);
          });
      case TaskView.inbox:
        return _tasks.where((t) => inInboxOf(t.raw, byId)).toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
      case TaskView.anytime:
        return _tasks.where((t) => inAnytime(t.raw, today)).toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
      case TaskView.someday:
        return _tasks.where((t) => inSomedayView(t.raw)).toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
    }
  }

  static double _position(Task task) => (task.raw['position'] as num?)?.toDouble() ?? 0;

  Future<void> _toggle(Task task) async {
    await widget.state.repo?.setCompleted(task, !task.isCompleted);
    await _load();
  }

  Future<void> _open(Task task) async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final projects = await repo.projects();
    if (!mounted) return;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TaskSheet(task: task, repo: repo, projects: projects),
    );
    await _load();
  }

  Future<void> _add() async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final projects = await repo.projects();
    if (!mounted) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NewTaskSheet(repo: repo, projects: projects),
    );
    if (created == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tasks = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OTDA'),
        actions: [
          if (widget.state.isSyncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(
              tooltip: 'Sync now',
              onPressed: () async {
                await widget.state.syncNow();
                await _load();
              },
              icon: const Icon(Icons.sync),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle),
            onSelected: (value) async {
              if (value == 'signOut') await widget.state.signOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text('${widget.state.account?.displayName ?? ''}\n${widget.state.account?.userEmail ?? ''}'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'signOut', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<TaskView>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: TaskView.today, label: Text('Today')),
                ButtonSegment(value: TaskView.inbox, label: Text('Inbox')),
                ButtonSegment(value: TaskView.anytime, label: Text('Any')),
                ButtonSegment(value: TaskView.someday, label: Text('Someday')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : tasks.isEmpty
                    ? RefreshIndicator(
                        onRefresh: () async {
                          await widget.state.syncNow();
                          await _load();
                        },
                        child: ListView(
                          children: [
                            const SizedBox(height: 96),
                            Center(
                              child: Text(
                                switch (_view) {
                                  TaskView.today => 'Nothing due today.',
                                  TaskView.inbox => 'Inbox is empty.',
                                  TaskView.anytime => 'Nothing waiting.',
                                  TaskView.someday => 'Nothing in Someday.',
                                },
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await widget.state.syncNow();
                          await _load();
                        },
                        child: ListView.builder(
                          itemCount: tasks.length,
                          itemBuilder: (context, index) => _TaskRow(
                            task: tasks[index],
                            projectName: tasks[index].projectId == null
                                ? null
                                : _projectNames[tasks[index].projectId],
                            onToggle: () => _toggle(tasks[index]),
                            onOpen: () => _open(tasks[index]),
                          ),
                        ),
                      ),
          ),
          _StatusBar(state: widget.state, open: tasks.length),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        tooltip: 'New task',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onToggle, required this.onOpen, this.projectName});

  final Task task;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final String? projectName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      if (task.dueDate != null) [task.dueDate, if (task.dueTime != null) task.dueTime].join(' '),
      ?projectName,
    ].join(' · ');
    return ListTile(
      leading: Checkbox(
        value: task.isCompleted,
        onChanged: (_) => onToggle(),
        shape: const CircleBorder(),
      ),
      title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: task.priority < 4
          ? Icon(Icons.flag, size: 18, color: task.priority == 1 ? theme.colorScheme.error : theme.colorScheme.primary)
          : null,
      onTap: onOpen,
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state, required this.open});

  final AppState state;
  final int open;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = state.lastSync;
    final when = last == null ? 'not synced yet' : 'synced ${_ago(last)}';
    final text = [
      '$open shown',
      when,
      if (state.pending > 0) '${state.pending} waiting to send',
      ?state.syncError,
    ].join(' · ');
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              state.syncError != null ? Icons.cloud_off : Icons.cloud_done,
              size: 14,
              color: state.syncError != null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
