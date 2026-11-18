import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/views.dart';
import 'new_task_sheet.dart';
import 'settings_screen.dart';
import 'task_sheet.dart';
import 'calendar_month.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// Where the shell is showing. The first four are the bottom bar; the rest come
/// from the sidebar, and none of them highlights a tab.
enum TaskView { inbox, today, upcoming, search, calendar, anytime, someday, project }

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

  /// The project whose list is showing, for [TaskView.project].
  String? _projectId;
  final _searchField = TextEditingController();
  String _query = '';
  List<Workspace> _workspaces = const [];
  String? _workspaceId;
  String _calendarDay = '';

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The sync line is a flicker on success and stays while there is a problem.
  bool _syncFlash = false;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _calendarDay = _today;
    _searchField.addListener(() {
      final text = _searchField.text;
      if (text == _query) return;
      setState(() => _query = text);
    });
    _load();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _searchField.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final tasks = await repo.tasks();
    final projects = await repo.projects();
    final workspaces = await repo.workspaces();
    if (!mounted) return;
    final defaultWorkspace = workspaces.where((w) => w.isDefault).map((w) => w.id).firstOrNull ??
        workspaces.map((w) => w.id).firstOrNull;
    setState(() {
      _tasks = tasks;
      _workspaces = workspaces;
      _workspaceId ??= defaultWorkspace;
      // A project without a workspace belongs to the account's default one.
      bool here(Project p) =>
          (p.workspaceId ?? defaultWorkspace) == _workspaceId || _workspaceId == null;
      _projectNames = {
        for (final p in projects)
          if (!p.isDeleted && here(p)) p.id: p.name,
      };
      _projectColors = {
        for (final p in projects)
          if (!p.isDeleted && here(p) && parseHexColor(p.color) != null) p.id: parseHexColor(p.color)!,
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
        // What is due, plus what was finished today: ticking one off moves it down
        // into "Done today" instead of vanishing.
        return _tasks.where((t) => inToday(t.raw, today) || _finishedToday(t, today)).toList()
          ..sort((a, b) {
            if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
            final ak = '${a.dueDate ?? a.deadline ?? '9999'}${a.dueTime ?? '99:99'}';
            final bk = '${b.dueDate ?? b.deadline ?? '9999'}${b.dueTime ?? '99:99'}';
            return ak.compareTo(bk);
          });
      case TaskView.inbox:
        return _tasks.where((t) => inInboxOf(t.raw, byId)).toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
      case TaskView.upcoming:
        return _tasks
            .where((t) =>
                !t.isCompleted &&
                !t.isDeleted &&
                t.dueDate != null &&
                t.dueDate!.compareTo(today) > 0)
            .toList()
          ..sort((a, b) => '${a.dueDate}${a.dueTime ?? '99:99'}'
              .compareTo('${b.dueDate}${b.dueTime ?? '99:99'}'));
      case TaskView.search:
        final needle = _query.trim().toLowerCase();
        if (needle.isEmpty) return const [];
        return _tasks.where((t) {
          if (t.isDeleted) return false;
          if (t.title.toLowerCase().contains(needle)) return true;
          final notes = t.raw['description']?.toString().toLowerCase() ?? '';
          return notes.contains(needle);
        }).toList()
          ..sort((a, b) => (a.isCompleted ? 1 : 0).compareTo(b.isCompleted ? 1 : 0));
      case TaskView.calendar:
        return _tasks
            .where((t) => !t.isDeleted && t.dueDate == _calendarDay)
            .toList()
          ..sort((a, b) => (a.dueTime ?? '99:99').compareTo(b.dueTime ?? '99:99'));
      case TaskView.project:
        return _tasks
            .where((t) => !t.isCompleted && !t.isDeleted && t.projectId == _projectId)
            .toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
      case TaskView.anytime:
        return _tasks.where((t) => inAnytime(t.raw, today)).toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
      case TaskView.someday:
        return _tasks.where((t) => inSomedayView(t.raw)).toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
    }
  }

  /// Completed today, in the device's own day.
  bool _finishedToday(Task task, String today) {
    final millis = task.completedAt;
    if (millis == null || task.isDeleted) return false;
    final when = DateTime.fromMillisecondsSinceEpoch(millis);
    final day = '${when.year.toString().padLeft(4, '0')}-'
        '${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
    return day == today;
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
    if (!mounted) return;
    // A successful sync says so for two seconds; a failure stays in the header.
    setState(() => _syncFlash = true);
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _syncFlash = false);
    });
  }

  void _go(TaskView view, {String? projectId}) {
    setState(() {
      _view = view;
      _projectId = projectId ?? _projectId;
      if (view != TaskView.search) {
        _searchField.clear();
        _query = '';
      }
      if (view == TaskView.calendar && _calendarDay.isEmpty) _calendarDay = _today;
    });
    // Close the sidebar when it is what navigated; never pop the screen itself.
    _scaffoldKey.currentState?.closeDrawer();
  }

  Future<void> _chooseWorkspace() async {
    if (_workspaces.length < 2) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final workspace in _workspaces)
              ListTile(
                leading: Icon(
                  workspace.id == _workspaceId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20,
                ),
                title: Text(workspace.name),
                subtitle: Text('${workspace.memberCount} member(s)'),
                onTap: () => Navigator.of(context).pop(workspace.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      setState(() => _workspaceId = chosen);
      await _load();
    }
  }

  static const _titles = {
    TaskView.today: 'Today',
    TaskView.inbox: 'Inbox',
    TaskView.upcoming: 'Upcoming',
    TaskView.search: 'Search',
    TaskView.calendar: 'Calendar',
    TaskView.anytime: 'Anytime',
    TaskView.someday: 'Someday',
  };

  String get _title =>
      _view == TaskView.project ? (_projectNames[_projectId] ?? 'Project') : _titles[_view]!;

  /// Today's list splits into what slipped and what is due now; the other
  /// views are flat. A String entry is a section header, a Task is a row.
  List<Object> _entries(List<Task> tasks) {
    final today = _today;
    if (_view == TaskView.today) {
      final open = tasks.where((t) => !t.isCompleted).toList();
      final done = tasks.where((t) => t.isCompleted).toList();
      final overdue = open.where((t) => (t.dueDate ?? '9999').compareTo(today) < 0).toList();
      final rest = open.where((t) => !overdue.contains(t)).toList();
      return [
        if (overdue.isNotEmpty) ...['Overdue', ...overdue],
        if (rest.isNotEmpty) ...['Today', ...rest],
        if (done.isNotEmpty) ...['Done today', ...done],
      ];
    }
    if (_view == TaskView.upcoming) {
      final out = <Object>[];
      String? last;
      for (final task in tasks) {
        final day = task.dueDate;
        if (day == null) continue;
        if (day != last) {
          out.add(friendlyDate(day, today));
          last = day;
        }
        out.add(task);
      }
      return out;
    }
    return tasks;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tasks = _visible;
    final entries = _entries(tasks);

    return Scaffold(
      key: _scaffoldKey,
      drawer: _AppDrawer(
        state: widget.state,
        view: _view,
        workspaces: _workspaces,
        workspaceId: _workspaceId,
        projects: _projectNames,
        projectColors: _projectColors,
        projectCounts: {
          for (final project in _projectNames.keys)
            project: _tasks.where((t) => !t.isCompleted && !t.isDeleted && t.projectId == project).length,
        },
        projectId: _projectId,
        onOpen: _go,
        onProject: (id) => _go(TaskView.project, projectId: id),
        onWorkspace: _chooseWorkspace,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              title: _view == TaskView.search
                  ? TextField(
                      controller: _searchField,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: 'Search tasks',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                      style: theme.textTheme.titleMedium,
                    )
                  : Text(
                      _title,
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
                subtitle: _view == TaskView.today
                    ? longToday(DateTime.now())
                    : (_view == TaskView.calendar ? friendlyDate(_calendarDay, _today) : null),
                state: widget.state,
                shown: tasks.length,
                showSync: _syncFlash,
              ),
            ),
            if (_view == TaskView.calendar)
              SliverToBoxAdapter(
                child: MonthCalendar(
                  tasks: _tasks,
                  initialMonth: DateTime.now(),
                  onDaySelected: (day) => setState(() {
                    _calendarDay = '${day.year.toString().padLeft(4, '0')}-'
                        '${day.month.toString().padLeft(2, '0')}-'
                        '${day.day.toString().padLeft(2, '0')}';
                  }),
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
      bottomNavigationBar: _BottomBar(view: _view, onSelect: _go),
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
  const _Header({
    required this.state,
    required this.shown,
    this.subtitle,
    this.showSync = false,
  });

  final String? subtitle;
  final AppState state;
  final int shown;

  /// True for a couple of seconds after a sync that worked.
  final bool showSync;

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
          if (error != null || showSync) ...[
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
      TaskView.upcoming => (Icons.date_range_outlined, 'Nothing coming up', 'Tasks with a future date show up here.'),
      TaskView.search => (Icons.search, 'Search your tasks', 'Type above to look through titles and notes.'),
      TaskView.calendar => (Icons.calendar_month_outlined, 'Nothing this day', 'Pick another day above.'),
      TaskView.project => (Icons.folder_open_outlined, 'Nothing open here', 'This project has no open tasks.'),
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

/// The sidebar: the workspace at the top (tap to switch), then the destinations
/// the bottom bar has no room for, then this workspace's projects.
class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.state,
    required this.view,
    required this.workspaces,
    required this.workspaceId,
    required this.projects,
    required this.projectColors,
    required this.projectCounts,
    required this.projectId,
    required this.onOpen,
    required this.onProject,
    required this.onWorkspace,
  });

  final AppState state;
  final TaskView view;
  final List<Workspace> workspaces;
  final String? workspaceId;
  final Map<String, String> projects;
  final Map<String, Color> projectColors;
  final Map<String, int> projectCounts;

  /// The project currently open, so its row is the selected one.
  final String? projectId;
  final void Function(TaskView) onOpen;
  final void Function(String projectId) onProject;
  final VoidCallback onWorkspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final workspaceName = current?.name ?? 'Workspace';
    final canSwitch = workspaces.length > 1;

    Widget destination(TaskView target, IconData icon, String label) => ListTile(
          dense: true,
          leading: Icon(icon, size: 20),
          title: Text(label),
          selected: view == target,
          selectedColor: scheme.primary,
          onTap: () => onOpen(target),
        );

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: canSwitch ? onWorkspace : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.spa_outlined, size: 16, color: scheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        workspaceName,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (canSwitch) Icon(Icons.expand_more_rounded, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            destination(TaskView.search, Icons.search, 'Search'),
            destination(TaskView.upcoming, Icons.date_range_outlined, 'Upcoming'),
            destination(TaskView.calendar, Icons.calendar_month_outlined, 'Calendar'),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Text(
                'PROJECTS (${projects.length})',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final entry in projects.entries)
                    ListTile(
                      dense: true,
                      selected: view == TaskView.project && projectId == entry.key,
                      leading: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: projectColors[entry.key] ?? scheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      title: Text(entry.value, overflow: TextOverflow.ellipsis),
                      trailing: projectCounts[entry.key] == 0
                          ? null
                          : Text('${projectCounts[entry.key]}', style: theme.textTheme.labelMedium),
                      onTap: () => onProject(entry.key),
                    ),
                  destination(TaskView.anytime, Icons.layers_outlined, 'Anytime'),
                  destination(TaskView.someday, Icons.bedtime_outlined, 'Someday'),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 14,
                child: Text(
                  (state.account?.displayName.isNotEmpty == true
                          ? state.account!.displayName
                          : '?')
                      .substring(0, 1)
                      .toUpperCase(),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              title: Text(state.account?.displayName ?? 'Signed in'),
              subtitle: Text('OpenTodo v${state.server?.version ?? '?'}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bottom bar: the four destinations the web app has. Views opened from the
/// sidebar highlight nothing here, which a NavigationBar cannot express.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.view, required this.onSelect});

  final TaskView view;
  final void Function(TaskView) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const items = [
      (TaskView.inbox, Icons.inbox_outlined, Icons.inbox, 'Inbox'),
      (TaskView.today, Icons.wb_sunny_outlined, Icons.wb_sunny, 'Today'),
      (TaskView.upcoming, Icons.date_range_outlined, Icons.date_range, 'Upcoming'),
      (TaskView.search, Icons.search_outlined, Icons.search, 'Search'),
    ];

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              for (final item in items)
                Expanded(
                  child: InkWell(
                    onTap: () => onSelect(item.$1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          view == item.$1 ? item.$3 : item.$2,
                          size: 22,
                          color: view == item.$1 ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.$4,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: view == item.$1 ? scheme.primary : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
