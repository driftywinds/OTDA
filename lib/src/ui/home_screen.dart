import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/views.dart';
import 'new_task_sheet.dart';
import 'settings_screen.dart';
import 'task_sheet.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

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
  Map<String, Color> _projectColors = const {};
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
      _projectColors = {
        for (final p in projects)
          if (!p.isDeleted && parseHexColor(p.color) != null) p.id: parseHexColor(p.color)!,
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

  Future<void> _refresh() async {
    await widget.state.syncNow();
    await _load();
  }

  static const _titles = {
    TaskView.today: 'Today',
    TaskView.inbox: 'Inbox',
    TaskView.anytime: 'Anytime',
    TaskView.someday: 'Someday',
  };

  /// Today's list splits into what slipped and what is due now; the other
  /// views are flat. A String entry is a section header, a Task is a row.
  List<Object> _entries(List<Task> tasks) {
    if (_view != TaskView.today) return tasks;
    final today = _today;
    final overdue = tasks.where((t) => (t.dueDate ?? '9999').compareTo(today) < 0).toList();
    if (overdue.isEmpty) return tasks;
    final rest = tasks.where((t) => !overdue.contains(t)).toList();
    return [
      'Overdue',
      ...overdue,
      if (rest.isNotEmpty) ...['Today', ...rest],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tasks = _visible;
    final entries = _entries(tasks);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              title: Text(
                _titles[_view]!,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              actions: [
                if (widget.state.isSyncing)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                else
                  IconButton(
                    tooltip: 'Sync now',
                    onPressed: _refresh,
                    icon: const Icon(Icons.sync_rounded),
                  ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SettingsScreen(state: widget.state)),
                  ),
                  icon: const Icon(Icons.tune_rounded),
                ),
                _AccountMenu(state: widget.state),
                const SizedBox(width: 8),
              ],
            ),
            SliverToBoxAdapter(
              child: _Header(
                subtitle: _view == TaskView.today ? longToday(DateTime.now()) : null,
                state: widget.state,
                shown: tasks.length,
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (tasks.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _EmptyState(view: _view))
            else ...[
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final entry = entries[index];
                    if (entry is String) {
                      return SectionLabel(entry, color: entry == 'Overdue' ? scheme.error : null);
                    }
                    final task = entry as Task;
                    return _TaskRow(
                      key: ValueKey(task.id),
                      task: task,
                      today: _today,
                      projectName: task.projectId == null ? null : _projectNames[task.projectId],
                      projectColor: task.projectId == null ? null : _projectColors[task.projectId],
                      onToggle: () => _toggle(task),
                      onOpen: () => _open(task),
                    );
                  },
                  childCount: entries.length,
                ),
              ),
              // Room for the add button to clear the last row.
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        tooltip: 'New task',
        child: const Icon(Icons.add_rounded, size: 28),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _view.index,
        onDestinationSelected: (i) => setState(() => _view = TaskView.values[i]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox), label: 'Inbox'),
          NavigationDestination(icon: Icon(Icons.layers_outlined), selectedIcon: Icon(Icons.layers), label: 'Anytime'),
          NavigationDestination(icon: Icon(Icons.bedtime_outlined), selectedIcon: Icon(Icons.bedtime), label: 'Someday'),
        ],
      ),
    );
  }
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = (state.account?.displayName ?? '').trim();
    final email = (state.account?.userEmail ?? '').trim();
    final seed = name.isNotEmpty ? name : email;
    final initial = seed.isEmpty ? '?' : seed.substring(0, 1).toUpperCase();
    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(0, 44),
      onSelected: (value) async {
        if (value == 'signOut') await state.signOut();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(name, style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface)),
              if (email.isNotEmpty)
                Text(email, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'signOut',
          child: Row(children: [Icon(Icons.logout_rounded, size: 20), SizedBox(width: 12), Text('Sign out')]),
        ),
      ],
      child: CircleAvatar(
        radius: 16,
        backgroundColor: scheme.primary.withValues(alpha: 0.14),
        child: Text(
          initial,
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// The big title, with the date or count and the sync state beneath it.
class _Header extends StatelessWidget {
  const _Header({required this.state, required this.shown, this.subtitle});

  final String? subtitle;
  final AppState state;
  final int shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final last = state.lastSync;
    final error = state.syncError;
    final sync = [
      last == null ? 'not synced yet' : 'synced ${_ago(last)}',
      if (state.pending > 0) '${state.pending} waiting to send',
    ].join(' · ');
    final count = shown == 1 ? '1 task' : '$shown tasks';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle == null ? count : '$subtitle · $count', style: muted),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                error != null ? Icons.cloud_off_rounded : Icons.cloud_done_outlined,
                size: 14,
                color: error != null ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  error ?? sync,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: error != null ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.view});

  final TaskView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, title, hint) = switch (view) {
      TaskView.today => (Icons.wb_sunny_outlined, 'Nothing due today', 'Enjoy the quiet, or add something with +.'),
      TaskView.inbox => (Icons.inbox_outlined, 'Inbox is empty', 'New tasks without a home land here.'),
      TaskView.anytime => (Icons.layers_outlined, 'Nothing waiting', 'Tasks with no date show up here.'),
      TaskView.someday => (Icons.bedtime_outlined, 'Nothing in Someday', 'Park ideas here for later.'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, size: 32, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(hint, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.today,
    required this.onToggle,
    required this.onOpen,
    this.projectName,
    this.projectColor,
  });

  final Task task;
  final String today;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final String? projectName;
  final Color? projectColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = task.dueDate;
    final days = date == null ? null : daysBetween(today, date);
    final overdue = days != null && days < 0;
    final estimate = task.estimateMinutes;

    final meta = <Widget>[
      if (date != null)
        MetaPill(
          icon: Icons.event_rounded,
          label: [friendlyDate(date, today), ?task.dueTime].join(' · '),
          color: overdue ? scheme.error : (days == 0 ? scheme.primary : null),
        ),
      if (estimate != null) MetaPill(icon: Icons.timelapse_rounded, label: durationLabel(estimate)),
      if (projectName != null)
        MetaPill(label: projectName!, dot: projectColor ?? scheme.primary),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Material(
        color: scheme.card,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                TaskCheck(done: task.isCompleted, priority: task.priority, onChanged: onToggle),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                            color: task.isCompleted ? scheme.onSurfaceVariant : scheme.onSurface,
                          ),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Wrap(spacing: 14, runSpacing: 2, children: meta),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
