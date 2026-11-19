import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import '../app_state.dart';
import '../data/models.dart';
import '../data/views.dart';
import '../e2ee/session.dart';
import 'e2ee_unlock_sheet.dart';
import 'new_task_sheet.dart';
import 'settings_screen.dart';
import 'task_sheet.dart';
import 'calendar_month.dart';
import '../data/occurrences.dart';
import '../reminders/service.dart';
import '../data/recurrence.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';
import 'workspace_icon.dart';

/// Where the shell is showing. The first four are the bottom bar; the rest come
/// from the sidebar, and none of them highlights a tab.
enum TaskView { inbox, today, upcoming, search, calendar, anytime, someday, history, project }

/// The task list over the local replica: readable and editable with no network.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Task> _tasks = const [];
  Map<String, String> _projectNames = const {};
  Map<String, Color> _projectColors = const {};
  Map<String, String> _projectIcons = const {};
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

  /// The day each task is listed under in Upcoming: its due date, or the next
  /// occurrence of a repeating task.
  Map<String, String> _upcomingDays = const {};

  /// Every occurrence between the calendar's window edges, so a daily task is
  /// shown on every day it falls due.
  ///
  /// shortcut: the window is today -3 to +9 months; a grid scrolled further than
  /// that shows no dots. Give MonthCalendar a month callback to make it exact.
  List<(String, Task)> _calendarOccurrences = const [];

  /// The sync line is a flicker on success and stays while there is a problem.
  bool _syncFlash = false;
  Timer? _syncTimer;

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    widget.state.e2eeLocked.addListener(_askForPassphrase);
    ReminderService.instance.pendingTask.addListener(_openPendingFromWidget);
    ReminderService.instance.pendingNewTask.addListener(_openPendingNewTask);
    super.initState();
    _calendarDay = _today;
    _searchField.addListener(() {
      final text = _searchField.text;
      if (text == _query) return;
      setState(() => _query = text);
    });
    // A link that launched the app arrived before this screen existed, so look once
    // the tasks are loaded.
    _load().then((_) {
      _openPendingFromWidget();
      _openPendingNewTask();
    });
  }

  /// The widget's "+" was tapped: open the new-task sheet on that project.
  Future<void> _openPendingNewTask() async {
    final request = ReminderService.instance.pendingNewTask.value;
    if (request == null || !mounted) return;
    ReminderService.instance.pendingNewTask.value = null;
    await _add(projectId: request.projectId);
  }

  /// A widget row was tapped: open that task once the replica has it.
  Future<void> _openPendingFromWidget() async {
    final id = ReminderService.instance.pendingTask.value;
    if (id == null || !mounted) return;
    ReminderService.instance.pendingTask.value = null;
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task != null) await _open(task);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
      widget.state.afterDataChanged();
    }
  }

  @override
  void dispose() {
    widget.state.e2eeLocked.removeListener(_askForPassphrase);
    ReminderService.instance.pendingTask.removeListener(_openPendingFromWidget);
    ReminderService.instance.pendingNewTask.removeListener(_openPendingNewTask);
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _searchField.dispose();
    super.dispose();
  }

  bool _askingForPassphrase = false;

  /// An encrypted account with no key here: ask once, then sync. Accounts without a
  /// key record never reach this, so a normal account behaves exactly as before.
  Future<void> _askForPassphrase() async {
    if (!mounted || _askingForPassphrase) return;
    if (!widget.state.e2eeLocked.value) return;
    _askingForPassphrase = true;
    try {
      final unlocked = await showE2eeUnlockSheet(context);
      if (!mounted) return;
      if (unlocked) {
        await _decryptWithProgress();
      } else {
        // Dismissed on purpose is not the end of it: a banner keeps the way back
        // until the vault is unlocked or the app is signed out.
        ScaffoldMessenger.of(context).showMaterialBanner(
          MaterialBanner(
            content: const Text('Encryption locked: nothing syncs until you unlock.'),
            actions: [
              TextButton(onPressed: _askForPassphrase, child: const Text('Unlock')),
            ],
          ),
        );
      }
    } finally {
      _askingForPassphrase = false;
    }
  }

  /// The first unlock decrypts every stored field, so it gets a real bar rather
  /// than a spinner that looks stuck.
  Future<void> _decryptWithProgress() async {
    final progress = E2eeSession.instance.progress;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, value, _) => AlertDialog(
          title: const Text('Unlocking your tasks'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value == null ? 'Starting…' : 'Decrypting ${(value * 100).round()}%'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: value),
            ],
          ),
        ),
      ),
    );
    try {
      await widget.state.afterUnlock();
      // The lists were built from the ciphertext the replica held before the
      // unlock; read them again now that the rows are plaintext.
      await _load();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _load() async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final today = _today;
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
      _projectIcons = {
        for (final p in projects)
          if (!p.isDeleted && here(p) && p.icon.isNotEmpty) p.id: p.icon,
      };
      final from = firstOfMonth(today, -3);
      final to = lastOfMonth(today, 9);
      _calendarOccurrences = occurrencesBetween(tasks, from, to);
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
        // Upcoming is every open task with a day ahead of today, plus a repeating
        // task whose stored due has passed: it is shown on its next occurrence, so
        // a monthly or daily task does not sit in the past and vanish from here.
        final dated = <(String, Task)>[
          for (final t in _tasks)
            if (upcomingDay(t, _tasks, today) case final day?) (day, t),
        ]..sort((a, b) => '${a.$1}${a.$2.dueTime ?? '99:99'}'
            .compareTo('${b.$1}${b.$2.dueTime ?? '99:99'}'));
        _upcomingDays = {for (final e in dated) e.$2.id: e.$1};
        return [for (final e in dated) e.$2];
      case TaskView.history:
        // The occurrence records: what was actually done or skipped, and when.
        final records = [
          for (final task in _tasks)
            if (task.raw['series_id'] != null &&
                (task.raw['occurrence_date']?.toString().isNotEmpty ?? false))
              task,
        ]..sort((a, b) => (b.raw['occurrence_date']?.toString() ?? '')
            .compareTo(a.raw['occurrence_date']?.toString() ?? ''));
        return records;
      case TaskView.search:
        final needle = _query.trim().toLowerCase();
        if (needle.isEmpty) return const [];
        return _tasks.where((t) {
          if (t.isDeleted) return false;
          if (t.title.toLowerCase().contains(needle)) return true;
          final notes = t.raw['description']?.toString().toLowerCase() ?? '';
          return notes.contains(needle);
        }).toList()
          // Most recent first: a search is nearly always for something just made.
          ..sort((a, b) {
            final open = (a.isCompleted ? 1 : 0).compareTo(b.isCompleted ? 1 : 0);
            if (open != 0) return open;
            return (b.createdAt ?? 0).compareTo(a.createdAt ?? 0);
          });
      case TaskView.calendar:
        return [
          for (final entry in _calendarOccurrences)
            if (entry.$1 == _calendarDay) entry.$2,
        ]..sort((a, b) => (a.dueTime ?? '99:99').compareTo(b.dueTime ?? '99:99'));
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
    // In Upcoming a done repeating task is listed on its next occurrence, which
    // is open and not due yet. Ticking it must not reopen the one done today.
    if (_view == TaskView.upcoming && task.isCompleted && isRecurring(task)) {
      final day = _upcomingDays[task.id];
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(day == null ? 'Already done for now.' : 'Done for now — it comes round again on ${friendlyDate(day, _today)}.'),
        ));
      return;
    }
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

  Future<void> _add({String? projectId}) async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final projects = await repo.projects();
    if (!mounted) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NewTaskSheet(repo: repo, projects: projects, initialProjectId: projectId),
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

  Future<void> _createProject(Map<String, Object?> fields) async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final created = await repo.createProject(
      fields['name'] as String? ?? '',
      color: fields['color'] as String?,
      icon: fields['icon'] as String?,
    );
    await _load();
    if (!mounted) return;
    _go(TaskView.project, projectId: created.id);
  }

  Future<void> _updateProject(String id, Map<String, Object?> fields) async {
    final repo = widget.state.repo;
    if (repo == null) return;
    await repo.updateProject(id, fields);
    await _load();
  }

  /// Projects are tombstoned one by one; the tasks keep their project id, which is
  /// what the server does with a deleted project too.
  Future<void> _deleteProjects(List<String> projectIds) async {
    final repo = widget.state.repo;
    if (repo == null) return;
    for (final id in projectIds) {
      await repo.trashProject(id);
    }
    if (_projectId != null && projectIds.contains(_projectId)) {
      _projectId = null;
      _view = TaskView.today;
    }
    await _load();
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
    TaskView.history: 'History',
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
        final day = _upcomingDays[task.id] ?? task.dueDate;
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

    return PopScope(
      // Back goes to Today from anywhere and only leaves the app from Today; a
      // drawer that is open eats the gesture first.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final scaffold = _scaffoldKey.currentState;
        if (scaffold?.isDrawerOpen ?? false) {
          scaffold!.closeDrawer();
          return;
        }
        if (_view == TaskView.today) {
          SystemNavigator.pop();
          return;
        }
        _go(TaskView.today);
      },
      child: Scaffold(
      key: _scaffoldKey,
      drawer: _AppDrawer(
        state: widget.state,
        view: _view,
        workspaces: _workspaces,
        workspaceId: _workspaceId,
        projects: _projectNames,
        projectColors: _projectColors,
        projectIcons: _projectIcons,
        projectCounts: {
          for (final project in _projectNames.keys)
            project: _tasks.where((t) => !t.isCompleted && !t.isDeleted && t.projectId == project).length,
        },
        projectId: _projectId,
        onOpen: _go,
        onProject: (id) => _go(TaskView.project, projectId: id),
        onCreateProject: _createProject,
        onUpdateProject: _updateProject,
        onDeleteProjects: _deleteProjects,
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
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                      ),
                    ),
              actions: [
                // Both actions sit in equal 48px boxes so the icons are evenly
                // spaced, and the spinner takes the same box instead of nudging
                // its neighbour while a sync runs.
                SizedBox(
                  width: 48,
                  height: 48,
                  child: widget.state.isSyncing
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: 'Sync now',
                          onPressed: _refresh,
                          icon: const Icon(Icons.sync_rounded),
                        ),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SettingsScreen(state: widget.state)),
                  ),
                  icon: const Icon(Icons.tune_rounded),
                ),
                const SizedBox(width: 4),
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
                  // A repeating task appears once per occurrence, so the grid's
                  // dots count what actually falls on each day.
                  tasks: [
                    for (final entry in _calendarOccurrences)
                      Task(entry.$2.id, {
                        ...entry.$2.raw,
                        'due': {'date': entry.$1},
                      }),
                  ],
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
                      dueOverride: switch (_view) {
                        TaskView.upcoming => _upcomingDays[task.id],
                        TaskView.calendar => _calendarDay,
                        _ => null,
                      },
                      // Upcoming lists a repeating task on its next occurrence, which
                      // is not done even though today's was.
                      showDone: !(_view == TaskView.upcoming && isRecurring(task)),
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
    ));
  }
}

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
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
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
    TaskView.history => (
        Icons.history_rounded,
        'Nothing done yet',
        'Occurrences you finish or skip show up here.',
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Two soft rings round the icon so the empty page still has a focal point.
          Container(
            width: 104,
            height: 104,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.06), shape: BoxShape.circle),
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
              ),
              child: Icon(icon, size: 32, color: scheme.primary),
            ),
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
    this.dueOverride,
    this.showDone = true,
  });

  final Task task;
  final String today;

  /// The day to show instead of `due` (Upcoming projects a repeating task).
  final String? dueOverride;

  /// Draw the task as finished when it is. False for a future occurrence of a
  /// repeating task, which is open even when the one before it was done.
  final bool showDone;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final String? projectName;
  final Color? projectColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = dueOverride ?? task.dueDate;
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
      if (isRecurring(task))
        MetaPill(icon: Icons.repeat_rounded, label: recurrenceLabel(task)),
      if (projectName != null)
        MetaPill(label: projectName!, dot: projectColor ?? scheme.primary),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: scheme.softShadow,
        ),
        child: Material(
          color: scheme.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: scheme.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  TaskCheck(done: task.isCompleted && showDone, priority: task.priority, onChanged: onToggle),
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
                              fontWeight: FontWeight.w600,
                              decoration: task.isCompleted && showDone ? TextDecoration.lineThrough : null,
                              decorationColor: scheme.onSurfaceVariant,
                              color: task.isCompleted && showDone ? scheme.onSurfaceVariant : scheme.onSurface,
                            ),
                          ),
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(spacing: 6, runSpacing: 4, children: meta),
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
    required this.projectIcons,
    required this.projectCounts,
    required this.projectId,
    required this.onOpen,
    required this.onProject,
    required this.onCreateProject,
    required this.onUpdateProject,
    required this.onDeleteProjects,
    required this.onWorkspace,
  });

  final AppState state;
  final TaskView view;
  final List<Workspace> workspaces;
  final String? workspaceId;
  final Map<String, String> projects;
  final Map<String, Color> projectColors;
  final Map<String, String> projectIcons;
  final Map<String, int> projectCounts;

  /// The project currently open, so its row is the selected one.
  final String? projectId;
  final void Function(TaskView) onOpen;
  final void Function(String projectId) onProject;
  final void Function(Map<String, Object?> fields) onCreateProject;
  final void Function(String projectId, Map<String, Object?> fields) onUpdateProject;
  final void Function(List<String> projectIds) onDeleteProjects;
  final VoidCallback onWorkspace;

  /// `v1.5.0` reads as `v1.5.0`, not `vv1.5.0`.
  static String _versionLabel(String? version) {
    if (version == null || version.isEmpty) return '?';
    return version.startsWith('v') ? version : 'v$version';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final workspaceName = current?.name ?? 'Workspace';
    final canSwitch = workspaces.length > 1;

    // Rows are inset from the drawer edge and highlighted as rounded pills.
    Widget inset(Widget child) =>
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1), child: child);

    // Every leading is the same 24px box: a project dot, a project icon, a
    // destination icon and the selection checkbox then all start their title at
    // the same x.
    Widget mark(Widget child) => SizedBox(width: 24, height: 24, child: Center(child: child));

    Widget destination(TaskView target, IconData icon, String label) {
      final selected = view == target;
      return inset(ListTile(
        dense: true,
        leading: mark(Icon(icon, size: 20)),
        title: Text(
          label,
          style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
        ),
        selected: selected,
        selectedColor: scheme.primary,
        onTap: () => onOpen(target),
      ));
    }

    const rule = Divider(height: 16, indent: 20, endIndent: 20);

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
                    Builder(builder: (context) {
                      // The owner picks an icon and a colour for each workspace;
                      // show theirs rather than one generic glyph.
                      final accent = parseHexColor(current?.color) ?? scheme.primary;
                      return Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(workspaceIcon(current?.icon ?? ''), size: 18, color: accent),
                      );
                    }),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        workspaceName,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (canSwitch)
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: scheme.field, shape: BoxShape.circle),
                        child: Icon(Icons.expand_more_rounded, size: 20, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
            rule,
            destination(TaskView.search, Icons.search, 'Search'),
            destination(TaskView.upcoming, Icons.date_range_outlined, 'Upcoming'),
            destination(TaskView.calendar, Icons.calendar_month_outlined, 'Calendar'),
            rule,
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _ProjectSection(
                    projects: projects,
                    colors: projectColors,
                    icons: projectIcons,
                    counts: projectCounts,
                    currentId: view == TaskView.project ? projectId : null,
                    onOpen: onProject,
                    onCreate: onCreateProject,
                    onUpdate: onUpdateProject,
                    onDelete: onDeleteProjects,
                    inset: inset,
                  ),
                  destination(TaskView.anytime, Icons.layers_outlined, 'Anytime'),
                  destination(TaskView.someday, Icons.bedtime_outlined, 'Someday'),
                  destination(TaskView.history, Icons.history_rounded, 'History'),
                ],
              ),
            ),
            rule,
            ListTile(
              dense: true,
              leading: AccountAvatar(state: state, size: 30),
              title: Text(
                state.account?.displayName ?? 'Signed in',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('OpenTodo ${_versionLabel(state.server?.version)}'),
              trailing: IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout_rounded, size: 20),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await state.signOut();
                },
              ),
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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.card,
        border: Border(top: BorderSide(color: scheme.cardBorder)),
      ),
      child: Material(
        color: Colors.transparent,
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
                          // The selected destination sits in a soft pill.
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            width: 52,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: view == item.$1
                                  ? scheme.primary.withValues(alpha: 0.14)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              view == item.$1 ? item.$3 : item.$2,
                              size: 22,
                              color: view == item.$1 ? scheme.primary : scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.$4,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: view == item.$1 ? FontWeight.w700 : FontWeight.w500,
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
      ),
    );
  }
}

/// The project list in the sidebar: open one, add one, edit one by holding it,
/// or select several and delete them together (with a confirmation, because a
/// tombstone is a delete).
class _ProjectSection extends StatefulWidget {
  const _ProjectSection({
    required this.projects,
    required this.colors,
    required this.icons,
    required this.counts,
    required this.currentId,
    required this.onOpen,
    required this.onCreate,
    required this.onUpdate,
    required this.onDelete,
    required this.inset,
  });

  final Map<String, String> projects;
  final Map<String, Color> colors;
  final Map<String, String> icons;
  final Map<String, int> counts;
  final String? currentId;
  final void Function(String projectId) onOpen;
  final void Function(Map<String, Object?> fields) onCreate;
  final void Function(String projectId, Map<String, Object?> fields) onUpdate;
  final void Function(List<String> projectIds) onDelete;
  final Widget Function(Widget child) inset;

  @override
  State<_ProjectSection> createState() => _ProjectSectionState();
}

class _ProjectSectionState extends State<_ProjectSection> {
  bool _selecting = false;
  final Set<String> _selected = {};

  /// A palette rather than a colour wheel: enough to tell projects apart, and the
  /// same names the web app uses.
  static const _palette = [
    '#64748b', '#3b82f6', '#6366f1', '#8b5cf6', '#ec4899',
    '#ef4444', '#f59e0b', '#10b981', '#14b8a6', '#0ea5e9',
  ];

  Future<void> _edit({String? id}) async {
    final hue = id == null ? _palette[1] : _hexOf(widget.colors[id]) ?? _palette[1];
    final result = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ProjectEditor(
        name: id == null ? '' : (widget.projects[id] ?? ''),
        color: hue,
        icon: id == null ? '' : (widget.icons[id] ?? ''),
        palette: _palette,
        editing: id != null,
      ),
    );
    if (result == null) return;
    if (id == null) {
      widget.onCreate(result);
    } else {
      widget.onUpdate(id, result);
    }
  }

  static String? _hexOf(Color? color) {
    if (color == null) return null;
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0')}';
  }

  /// Holding a project offers what you would want to do with it.
  Future<void> _menu(String id) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                widget.projects[id] ?? 'Project',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('Hold to edit or delete'),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit project'),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete project'),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _edit(id: id);
    } else {
      await _confirmDelete([id]);
    }
  }

  Future<void> _confirmDelete([List<String>? only]) async {
    final ids = only ?? _selected.toList();
    final names = [
      for (final id in ids)
        if (widget.projects[id] != null) widget.projects[id]!,
    ];
    if (names.isEmpty) return;
    final shown = names.take(5).join(', ');
    final more = names.length > 5 ? ' and ${names.length - 5} more' : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(names.length == 1 ? 'Delete this project?' : 'Delete ${names.length} projects?'),
        content: Text('$shown$more', style: Theme.of(context).textTheme.bodyMedium),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    widget.onDelete(ids);
  }

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 12, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'PROJECTS (${widget.projects.length})',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: _selecting ? 'Done selecting' : 'Delete projects',
                visualDensity: VisualDensity.compact,
                onPressed: widget.projects.isEmpty
                    ? null
                    : () => setState(() {
                          _selecting = !_selecting;
                          _selected.clear();
                        }),
                icon: Icon(_selecting ? Icons.close_rounded : Icons.delete_outline_rounded, size: 18),
              ),
              IconButton(
                tooltip: 'New project',
                visualDensity: VisualDensity.compact,
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded, size: 18),
              ),
            ],
          ),
        ),
        if (_selecting && _selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _confirmDelete,
              icon: const Icon(Icons.delete_rounded, size: 16),
              label: Text('Delete ${_selected.length}'),
            ),
          ),
        for (final entry in widget.projects.entries)
          widget.inset(ListTile(
            dense: true,
            selected: !_selecting && widget.currentId == entry.key,
            leading: _selecting
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: Transform.scale(
                        scale: 0.85,
                        child: Checkbox(
                          value: _selected.contains(entry.key),
                          onChanged: (_) => _toggle(entry.key),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  )
                : SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: _ProjectMark(
                        color: widget.colors[entry.key] ?? scheme.primary,
                        icon: widget.icons[entry.key] ?? '',
                      ),
                    ),
                  ),
            title: Text(
              entry.value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: widget.currentId == entry.key ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            trailing: widget.counts[entry.key] == 0
                ? null
                : Text(
                    '${widget.counts[entry.key]}',
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
            onTap: () => _selecting ? _toggle(entry.key) : widget.onOpen(entry.key),
            onLongPress: () => _menu(entry.key),
          )),
      ],
    );
  }
}

/// A project's mark: its chosen icon, or the colour dot it falls back to.
class _ProjectMark extends StatelessWidget {
  const _ProjectMark({required this.color, required this.icon});

  final Color color;
  final String icon;

  @override
  Widget build(BuildContext context) {
    if (icon.isEmpty) {
      return Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 5)],
        ),
      );
    }
    return Icon(workspaceIcon(icon), size: 18, color: color);
  }
}

/// Creates or edits a project: name, colour and icon, the three fields the server
/// lets a project carry.
class _ProjectEditor extends StatefulWidget {
  const _ProjectEditor({
    required this.name,
    required this.color,
    required this.icon,
    required this.palette,
    required this.editing,
  });

  final String name;
  final String color;
  final String icon;
  final List<String> palette;
  final bool editing;

  @override
  State<_ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<_ProjectEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late String _color = widget.color;
  late String _icon = widget.icon;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(<String, Object?>{
      'name': name,
      'color': _color,
      'icon': _icon.isEmpty ? null : _icon,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icons = workspaceIconNames;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.editing ? 'Edit project' : 'New project',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: !widget.editing,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            Text('Colour', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final hex in widget.palette)
                  InkWell(
                    onTap: () => setState(() => _color = hex),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: parseHexColor(hex) ?? scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: _color == hex
                          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Icon', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                InkWell(
                  onTap: () => setState(() => _icon = ''),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _icon.isEmpty ? scheme.primary : scheme.cardBorder,
                        width: _icon.isEmpty ? 2 : 1,
                      ),
                    ),
                    child: Icon(Icons.circle, size: 10, color: parseHexColor(_color) ?? scheme.primary),
                  ),
                ),
                for (final name in icons)
                  InkWell(
                    onTap: () => setState(() => _icon = name),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _icon == name ? scheme.primary : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        workspaceIcon(name),
                        size: 18,
                        color: _icon == name ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(widget.editing ? 'Save' : 'Create'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
