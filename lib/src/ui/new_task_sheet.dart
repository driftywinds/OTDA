import 'dart:async';

import 'package:flutter/services.dart' show SystemChannels;
import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/recurrence.dart';
import '../data/repo.dart';
import '../quickadd_bridge.dart';
import 'composer_state.dart';
import 'format.dart';
import 'highlight_controller.dart';
import 'repeat_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// The composer behind the plus button: one line to type, a preview of what the
/// line was understood to mean, and the date, time, duration, repeat, priority
/// and project within reach.
///
/// A value set by a control wins over the same value parsed from the line, and
/// clearing the line clears only what the line had contributed — see
/// [ComposerState].
class NewTaskSheet extends StatefulWidget {
  const NewTaskSheet({
    super.key,
    required this.repo,
    required this.projects,
    this.initialProjectId,
    this.initialParent,
  });

  final Repo repo;
  final List<Project> projects;
  final String? initialProjectId;

  /// A task to nest the new one under: the composer opens with the parent chip
  /// filled and the project fixed to the parent's.
  final Task? initialParent;

  @override
  State<NewTaskSheet> createState() => _NewTaskSheetState();
}

class _NewTaskSheetState extends State<NewTaskSheet> {
  final _input = HighlightingController();
  Timer? _debounce;

  late final ComposerState _values;
  Task? _parent;
  List<Task> _allTasks = const [];
  bool _loadingParents = true;
  ParsedLine _parsed = const ParsedLine(title: '');
  bool _saving = false;
  String? _lastParsedText;

  /// The repeat sheet's per-task reminder choice, written once the task exists.
  int? _reminderMinutes;

  /// Held so the popup can focus the line and raise the keyboard itself: in the
  /// widget's translucent window the autofocus request can land before the window
  /// has input focus, and Android then drops it.
  final _titleFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _parent = widget.initialParent;
    _values = ComposerState(projectId: _parent?.projectId ?? widget.initialProjectId);
    _input.addListener(_onChanged);
    unawaited(_loadParentCandidates());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _titleFocus.requestFocus();
      // Wait for the sheet's entrance to finish rather than for a timer, then ask
      // for the keyboard: in the widget's translucent window the first request can
      // be dropped before the window holds focus.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      try {
        await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      } on Object {
        // no text input connection (or none on this platform): nothing to raise
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.removeListener(_onChanged);
    _input.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  Future<void> _loadParentCandidates() async {
    try {
      final tasks = await widget.repo.tasks();
      if (!mounted) return;
      setState(() {
        _allTasks = [for (final task in tasks) if (!task.isDeleted) task];
        _loadingParents = false;
      });
    } on Object {
      if (mounted) setState(() => _loadingParents = false);
    }
  }

  Future<void> _pickParent() async {
    if (_loadingParents) return;
    final chosen = await showModalBottomSheet<Task>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _ParentPicker(
        tasks: _allTasks,
        projects: widget.projects,
        selectedId: _parent?.id,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _parent = chosen;
      // A subtask must stay in its parent's project; the project chip is fixed.
      _values.projectId = chosen.projectId;
      _values.claim('project');
    });
  }

  /// Parses after a pause, the way the web app does, so the preview follows the
  /// typing without a request per keystroke.
  void _onChanged() {
    // Setting the highlights notifies this listener too, and so do caret moves;
    // only a change of the text itself needs a new parse.
    if (_input.text == _lastParsedText) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      final line = _input.text;
      _lastParsedText = line;
      final parsed = parseLine(line,
          today: todayString(), now: nowString(), projects: widget.projects);
      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _input.highlights = parsed.highlights;
        _values.applyParsed(parsed);
      });
    });
  }

  void _clearDue() => setState(() {
        _values.dueDate = null;
        _values.dueTime = null;
        _values.release('due');
      });

  void _clearEstimate() => setState(() {
        _values.estimate = null;
        _values.release('estimate');
      });

  void _clearRecurrence() => setState(() {
        _values.recurrence = null;
        _values.release('recurrence');
      });

  void _clearPriority() => setState(() {
        _values.priority = 4;
        _values.release('priority');
      });

  void _clearParent() => setState(() {
        _parent = null;
        _values.release('project');
      });

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _values.dueDate == null ? now : DateTime.tryParse(_values.dueDate!) ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _values.dueDate = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
      _values.claim('due');
    });
  }

  Future<void> _pickTime() async {
    final parts = (_values.dueTime ?? '09:00').split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.tryParse(parts.first) ?? 9, minute: int.tryParse(parts.last) ?? 0),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _values.dueTime = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      _values.dueDate ??= todayString();
      _values.claim('due');
    });
  }

  Future<void> _save() async {
    final title = _parsed.title.isNotEmpty ? _parsed.title : _input.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final fields = composeTaskFields(
      parsed: _parsed,
      dueDate: _values.dueDate,
      dueTime: _values.dueTime,
      estimate: _values.estimate,
      recurrence: _values.recurrence,
      priority: _values.priority,
      projectId: _values.projectId,
    );
    // A quick-add line names labels; a task stores ids.
    final named = fields.remove('labels');
    if (named is List && named.isNotEmpty) {
      final ids = await widget.repo.resolveLabelNames(named);
      if (ids.isNotEmpty) fields['labels'] = ids;
    }
    final parent = _parent;
    if (parent != null) {
      fields['parent_id'] = parent.id;
      fields['position'] = await widget.repo.nextChildPosition(parent.id);
    }
    if (!mounted) return;
    final created = await widget.repo.createTask(
      title,
      projectId: parent?.projectId ?? _values.projectId,
      extra: fields,
    );
    if (_reminderMinutes != null) {
      await widget.repo.setTaskReminderOffset(created, _reminderMinutes);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  String get _estimateText {
    final minutes = _values.estimate;
    if (minutes == null) return 'Duration';
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
  }

  String get _projectName {
    if (_parent != null) {
      if (_parent!.projectId == null) return 'Inbox';
      for (final project in widget.projects) {
        if (project.id == _parent!.projectId) return project.name;
      }
      return 'Parent project';
    }
    if (_values.projectId == null) return 'Inbox';
    for (final project in widget.projects) {
      if (project.id == _values.projectId) return project.name;
    }
    return 'Project';
  }

  String get _parentLabel {
    final parent = _parent;
    if (parent == null) return 'Parent';
    final title = parent.title;
    return title.length > 28 ? '${title.substring(0, 27)}…' : title;
  }

  /// The line under the input: where the task will land, and what is set on it.
  /// What the line was understood to mean shows first; the values a person chose
  /// with the icons show when the line contributed none, each one tappable to
  /// change and clearable.
  List<Widget> _preview(ThemeData theme) {
    final scheme = theme.colorScheme;
    Widget chip(String label, IconData icon, {bool muted = false}) => Chip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: muted ? BorderSide(color: scheme.outlineVariant) : BorderSide.none,
          backgroundColor: muted ? null : scheme.primary.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          avatar: Icon(icon, size: 14, color: muted ? scheme.onSurfaceVariant : scheme.primary),
          label: Text(label),
          labelStyle: theme.textTheme.labelMedium
              ?.copyWith(color: muted ? scheme.onSurfaceVariant : scheme.primary),
        );

    final recognised = <Widget>[
      for (final label in _parsed.chips) chip(label, Icons.auto_awesome),
      // A `#name` that matched no project stays in the title; say so rather than
      // ignoring it silently.
      for (final miss in _parsed.unmatched) chip('$miss — no match', Icons.help_outline, muted: true),
    ];

    final today = todayString();
    final chosen = <Widget>[
      if (_values.dueDate != null)
        ValueChip(
          icon: Icons.event_rounded,
          label: [friendlyDate(_values.dueDate!, today), ?_values.dueTime].join(' · '),
          onTap: _pickDate,
          onClear: _clearDue,
        ),
      if (_values.estimate != null)
        ValueChip(
          icon: Icons.timelapse_rounded,
          label: _estimateText,
          onTap: () => _showDurationMenu(),
          onClear: _clearEstimate,
        ),
      if (_values.recurrence != null)
        ValueChip(
          icon: Icons.repeat_rounded,
          label: recurrenceLabelOf(_values.recurrence!),
          onTap: _showRepeatSheet,
          onClear: _clearRecurrence,
        ),
      if (_values.priority < 4)
        ValueChip(
          icon: Icons.flag_rounded,
          label: 'P${_values.priority}',
          color: priorityColor(_values.priority, scheme),
          onTap: () => _showPriorityMenu(),
          onClear: _clearPriority,
        ),
    ];

    final shown = <Widget>[
      ValueChip(
        icon: _values.projectId == null ? Icons.inbox_outlined : Icons.folder_outlined,
        label: _projectName,
        muted: _values.projectId == null,
        dropdown: _parent == null,
        onTap: _parent == null ? () => _showProjectMenu() : null,
      ),
      ...(recognised.isNotEmpty ? recognised : chosen),
      if (_parent != null)
        ValueChip(
          icon: Icons.account_tree_outlined,
          label: _parentLabel,
          onTap: _pickParent,
          onClear: _clearParent,
        ),
    ];

    final nothingSet = recognised.isEmpty && chosen.isEmpty && _parent == null;
    return [
      Wrap(spacing: 6, runSpacing: 6, children: shown),
      if (nothingSet)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _input.text.trim().isEmpty
                ? 'Type a task — "call Sam tomorrow 3pm p1 +#work 30m"'
                : 'No date, repeat or project understood yet',
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _titleFocus,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'What needs doing?',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  IconButton.filled(
                    style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_upward),
                    tooltip: 'Add task',
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _preview(theme)),
              ),
              const Divider(),
              const SizedBox(height: 8),
              PropIconBar(
                columns: 6,
                children: [
                  PropIconButton(
                    icon: Icons.event_rounded,
                    tooltip: 'Date',
                    active: _values.dueDate != null,
                    onTap: _pickDate,
                  ),
                  PropIconButton(
                    icon: Icons.schedule_rounded,
                    tooltip: 'Time',
                    active: _values.dueTime != null,
                    onTap: _pickTime,
                  ),
                  PropIconButton(
                    icon: Icons.timelapse_rounded,
                    tooltip: 'Duration',
                    active: _values.estimate != null,
                    onTap: () => _showDurationMenu(),
                  ),
                  PropIconButton(
                    icon: Icons.repeat_rounded,
                    tooltip: 'Repeat',
                    active: _values.recurrence != null,
                    onTap: _showRepeatSheet,
                  ),
                  PropIconButton(
                    icon: Icons.flag_rounded,
                    tooltip: 'Priority',
                    active: _values.priority < 4,
                    color: priorityColor(_values.priority, theme.colorScheme),
                    onTap: () => _showPriorityMenu(),
                  ),
                  PropIconButton(
                    icon: Icons.account_tree_outlined,
                    tooltip: 'Parent',
                    active: _parent != null,
                    onTap: _loadingParents ? null : _pickParent,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDurationMenu() async {
    const presets = [15, 30, 45, 60, 90, 120, 180, 240];
    final choice = await showChoiceSheet<int>(
      context,
      title: 'Duration',
      selected: _values.estimate,
      items: [for (final minutes in presets) ChoiceItem(minutes, _durationLabel(minutes))],
    );
    if (choice == null || !mounted) return;
    setState(() {
      _values.estimate = choice;
      _values.claim('estimate');
    });
  }

  static String _durationLabel(int minutes) =>
      minutes < 60 ? '${minutes}m' : (minutes % 60 == 0 ? '${minutes ~/ 60}h' : '${minutes ~/ 60}h ${minutes % 60}m');

  Future<void> _showRepeatSheet() async {
    final due = _values.dueDate == null
        ? null
        : <String, Object?>{'date': _values.dueDate, 'time': ?_values.dueTime};
    final result = await showRepeatSheet(
      context,
      today: todayString(),
      due: due,
      recurrence: _values.recurrence ?? '',
      reminderMinutes: _reminderMinutes,
    );
    if (result == null || !mounted) return;
    setState(() {
      final rule = result.rule.trim();
      _values.recurrence = rule.isEmpty ? null : rule;
      if (rule.isEmpty) {
        _values.release('recurrence');
      } else {
        _values.claim('recurrence');
      }
      if (result.due == null) {
        _values.dueDate = null;
        _values.dueTime = null;
        _values.release('due');
      } else {
        _values.dueDate = result.due!['date']?.toString();
        _values.dueTime = result.due!['time']?.toString();
        _values.claim('due');
      }
      _reminderMinutes = result.reminderMinutes;
    });
  }

  Future<void> _showPriorityMenu() async {
    final choice = await showChoiceSheet<int>(
      context,
      title: 'Priority',
      selected: _values.priority,
      items: const [
        ChoiceItem(1, 'P1 — highest', icon: Icons.flag_rounded),
        ChoiceItem(2, 'P2', icon: Icons.flag_rounded),
        ChoiceItem(3, 'P3', icon: Icons.flag_rounded),
        ChoiceItem(4, 'P4 — default', icon: Icons.outlined_flag_rounded),
      ],
    );
    if (choice == null || !mounted) return;
    setState(() {
      _values.priority = choice;
      _values.claim('priority');
    });
  }

  Future<void> _showProjectMenu() async {
    // The Inbox is the empty id, so that a dismissed sheet (null) is told apart
    // from choosing it.
    final choice = await showChoiceSheet<String>(
      context,
      title: 'Project',
      selected: _values.projectId ?? '',
      items: [
        const ChoiceItem('', 'Inbox', icon: Icons.inbox_outlined),
        for (final project in widget.projects)
          if (!project.isDeleted && !project.isArchived)
            ChoiceItem(project.id, project.name, icon: Icons.folder_outlined),
      ],
    );
    if (choice == null || !mounted) return;
    setState(() {
      _values.projectId = choice.isEmpty ? null : choice;
      _values.claim('project');
    });
  }
}

class _ParentPicker extends StatefulWidget {
  const _ParentPicker({required this.tasks, required this.projects, this.selectedId});

  final List<Task> tasks;
  final List<Project> projects;
  final String? selectedId;

  @override
  State<_ParentPicker> createState() => _ParentPickerState();
}

class _ParentPickerState extends State<_ParentPicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final projectNames = {for (final project in widget.projects) project.id: project.name};
    final shown = [
      for (final task in widget.tasks)
        if (query.isEmpty ||
            task.title.toLowerCase().contains(query) ||
            (projectNames[task.projectId] ?? '').toLowerCase().contains(query))
          task,
    ].take(300).toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Make it a subtask of…', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _search,
                  autofocus: false,
                  decoration: const InputDecoration(
                    hintText: 'Search tasks or projects',
                    prefixIcon: Icon(Icons.search_rounded),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.tasks.isEmpty
                ? Center(
                    child: Text(
                      'No tasks to nest under yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : shown.isEmpty
                    ? Center(
                        child: Text(
                          'No task matches “${_search.text.trim()}”.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: shown.length,
                        itemBuilder: (context, index) {
                          final task = shown[index];
                          return ListTile(
                            leading: Icon(
                              task.parentId == null ? Icons.check_circle_outline : Icons.subdirectory_arrow_right,
                              size: 20,
                            ),
                            title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [
                                projectNames[task.projectId] ?? 'Inbox',
                                if (task.parentId != null) 'already a subtask',
                                if (task.isCompleted) 'completed',
                              ].join(' · '),
                            ),
                            trailing: task.id == widget.selectedId ? const Icon(Icons.check_rounded, size: 20) : null,
                            onTap: () => Navigator.of(context).pop(task),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// What the composer will write: each control value when the person set one,
/// otherwise what the line was parsed into.
Map<String, Object?> composeTaskFields({
  required ParsedLine parsed,
  required int priority,
  String? dueDate,
  String? dueTime,
  int? estimate,
  String? recurrence,
  String? projectId,
}) {
  final parsedDue = parsed.fields['due'];
  final due = dueDate != null
      ? <String, Object?>{'date': dueDate, 'time': ?dueTime}
      : parsedDue;
  final minutes = estimate ?? (parsed.fields['estimate_minutes'] as num?)?.toInt();
  final repeat = recurrence ?? parsed.fields['recurrence']?.toString();
  final rank = priority != 4 ? priority : ((parsed.fields['priority'] as num?)?.toInt() ?? 4);

  return <String, Object?>{
    'priority': rank,
    'due': ?due,
    'estimate_minutes': ?minutes,
    if (repeat != null && repeat.isNotEmpty) 'recurrence': repeat,
    // Everything else the line set (labels, start, sector…).
    // shortcut: reminders and spent time are not written yet — they need their
    // own calls (a reminder, a time entry), so they are dropped rather than sent
    // as task fields the server would refuse.
    for (final entry in parsed.fields.entries)
      if (!const {
        'due',
        'priority',
        'estimate_minutes',
        'recurrence',
        'project_id',
        'title',
        'labels',
        'reminders',
        'spent_minutes',
      }.contains(entry.key))
        entry.key: entry.value,
  };
}
