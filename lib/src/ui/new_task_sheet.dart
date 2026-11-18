import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../quickadd_bridge.dart';
import 'composer_state.dart';
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
  const NewTaskSheet({super.key, required this.repo, required this.projects, this.initialProjectId});

  final Repo repo;
  final List<Project> projects;
  final String? initialProjectId;

  @override
  State<NewTaskSheet> createState() => _NewTaskSheetState();
}

class _NewTaskSheetState extends State<NewTaskSheet> {
  final _input = TextEditingController();
  Timer? _debounce;

  late final ComposerState _values = ComposerState(projectId: widget.initialProjectId);
  ParsedLine _parsed = const ParsedLine(title: '');
  bool _saving = false;

  // `showMenu` opens against a position, so each menu chip needs its own anchor.
  final _durationKey = GlobalKey();
  final _repeatKey = GlobalKey();
  final _priorityKey = GlobalKey();
  final _projectKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _input.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.removeListener(_onChanged);
    _input.dispose();
    super.dispose();
  }

  /// Parses after a pause, the way the web app does, so the preview follows the
  /// typing without a request per keystroke.
  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      final line = _input.text;
      final parsed = parseLine(line,
          today: todayString(), now: nowString(), projects: widget.projects);
      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _values.applyParsed(parsed);
      });
    });
  }

  /// Where a menu opens: anchored to the chip that asked for it.
  ///
  /// `showMenu` requires exactly one of `position`/`positionBuilder`. Passing
  /// neither asserts in debug and dereferences a null position in release, which
  /// is the blank screen this used to show.
  RelativeRect _menuPosition(GlobalKey anchor) {
    final box = anchor.currentContext!.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    return RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlay.size,
    );
  }

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

  Future<void> _pickCustom(String title, String? initial, void Function(String) apply) async {
    final controller = TextEditingController(text: initial ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'every week'),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Set')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !mounted) return;
    setState(() => apply(value.trim()));
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
    if (!mounted) return;
    await widget.repo.createTask(title, projectId: _values.projectId, extra: fields);
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
    if (_values.projectId == null) return 'Inbox';
    for (final project in widget.projects) {
      if (project.id == _values.projectId) return project.name;
    }
    return 'Project';
  }

  /// The line under the input: what the line was understood to mean.
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
    if (recognised.isNotEmpty) {
      return [Wrap(spacing: 6, runSpacing: 4, children: recognised)];
    }

    final chosen = <Widget>[
      if (_values.dueDate != null) chip([_values.dueDate, ?_values.dueTime].join(' '), Icons.event),
      if (_values.estimate != null) chip(_estimateText, Icons.timelapse),
      if (_values.recurrence != null) chip(_values.recurrence!, Icons.repeat),
      if (_values.priority < 4) chip('P${_values.priority}', Icons.flag),
      if (_values.projectId != null) chip(_projectName, Icons.folder),
    ];
    if (chosen.isNotEmpty) return [Wrap(spacing: 6, runSpacing: 4, children: chosen)];

    return [
      Text(
        _input.text.trim().isEmpty
            ? 'Type a task — "call Sam tomorrow 3pm p1 +#work 30m"'
            : 'No date, repeat or project understood yet',
        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _preview(theme)),
              ),
              const Divider(),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  PropChip(
                    icon: Icons.event_rounded,
                    label: _values.dueDate ?? 'Date',
                    active: _values.dueDate != null,
                    onTap: _pickDate,
                    onClear: _values.dueDate == null
                        ? null
                        : () => setState(() {
                              _values.dueDate = null;
                              _values.dueTime = null;
                              _values.release('due');
                            }),
                  ),
                  PropChip(
                    icon: Icons.schedule,
                    label: _values.dueTime ?? 'Time',
                    active: _values.dueTime != null,
                    onTap: _pickTime,
                    onClear: _values.dueTime == null
                        ? null
                        : () => setState(() {
                              _values.dueTime = null;
                              _values.release('due');
                            }),
                  ),
                  PropChip(
                    key: _durationKey,
                    icon: Icons.timelapse,
                    label: _estimateText,
                    active: _values.estimate != null,
                    onTap: () => _showDurationMenu(_durationKey),
                    onClear: _values.estimate == null
                        ? null
                        : () => setState(() {
                              _values.estimate = null;
                              _values.release('estimate');
                            }),
                  ),
                  PropChip(
                    key: _repeatKey,
                    icon: Icons.repeat,
                    label: _values.recurrence ?? 'Repeat',
                    active: _values.recurrence != null,
                    onTap: () => _showRepeatMenu(_repeatKey),
                    onClear: _values.recurrence == null
                        ? null
                        : () => setState(() {
                              _values.recurrence = null;
                              _values.release('recurrence');
                            }),
                  ),
                  PropChip(
                    key: _priorityKey,
                    icon: Icons.flag_rounded,
                    label: _values.priority < 4 ? 'P${_values.priority}' : 'Priority',
                    active: _values.priority < 4,
                    color: priorityColor(_values.priority, theme.colorScheme),
                    onTap: () => _showPriorityMenu(_priorityKey),
                    onClear: _values.priority < 4
                        ? () => setState(() {
                              _values.priority = 4;
                              _values.release('priority');
                            })
                        : null,
                  ),
                  PropChip(
                    key: _projectKey,
                    icon: Icons.folder_outlined,
                    label: _projectName,
                    active: _values.projectId != null,
                    onTap: () => _showProjectMenu(_projectKey),
                    onClear: _values.projectId == null
                        ? null
                        : () => setState(() {
                              _values.projectId = null;
                              _values.release('project');
                            }),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDurationMenu(GlobalKey anchor) async {
    const presets = [15, 30, 45, 60, 90, 120, 180, 240];
    final choice = await showMenu<int>(
      context: context,
      position: _menuPosition(anchor),
      initialValue: _values.estimate,
      items: [
        for (final minutes in presets)
          PopupMenuItem(value: minutes, child: Text(_durationLabel(minutes))),
      ],
    );
    if (choice == null || !mounted) return;
    setState(() {
      _values.estimate = choice;
      _values.claim('estimate');
    });
  }

  static String _durationLabel(int minutes) =>
      minutes < 60 ? '${minutes}m' : (minutes % 60 == 0 ? '${minutes ~/ 60}h' : '${minutes ~/ 60}h ${minutes % 60}m');

  Future<void> _showRepeatMenu(GlobalKey anchor) async {
    const presets = ['every day', 'every weekday', 'every week', 'every month', 'every year'];
    final choice = await showMenu<String>(
      context: context,
      position: _menuPosition(anchor),
      initialValue: _values.recurrence,
      items: [
        for (final rule in presets) PopupMenuItem(value: rule, child: Text(rule)),
        const PopupMenuItem(value: '__custom', child: Text('Custom…')),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == '__custom') {
      await _pickCustom('Repeat', _values.recurrence ?? 'every week', (value) {
        _values.recurrence = value;
        _values.claim('recurrence');
      });
    } else {
      setState(() {
        _values.recurrence = choice;
        _values.claim('recurrence');
      });
    }
  }

  Future<void> _showPriorityMenu(GlobalKey anchor) async {
    final choice = await showMenu<int>(
      context: context,
      position: _menuPosition(anchor),
      initialValue: _values.priority,
      items: const [
        PopupMenuItem(value: 1, child: Text('P1 — highest')),
        PopupMenuItem(value: 2, child: Text('P2')),
        PopupMenuItem(value: 3, child: Text('P3')),
        PopupMenuItem(value: 4, child: Text('P4 — default')),
      ],
    );
    if (choice == null || !mounted) return;
    setState(() {
      _values.priority = choice;
      _values.claim('priority');
    });
  }

  Future<void> _showProjectMenu(GlobalKey anchor) async {
    final choice = await showMenu<String?>(
      context: context,
      position: _menuPosition(anchor),
      initialValue: _values.projectId,
      items: [
        const PopupMenuItem<String?>(value: null, child: Text('Inbox')),
        for (final project in widget.projects)
          if (!project.isDeleted && !project.isArchived)
            PopupMenuItem<String?>(value: project.id, child: Text(project.name)),
      ],
    );
    if (!mounted) return;
    setState(() {
      _values.projectId = choice;
      _values.claim('project');
    });
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
