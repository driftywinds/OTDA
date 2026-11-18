import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../quickadd_bridge.dart';
import 'composer_state.dart';

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
  /// typing without working on every keystroke. The parse is local, so this
  /// costs nothing but arithmetic.
  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      final parsed = parseLine(
        _input.text,
        today: todayString(),
        now: nowString(),
        projects: widget.projects,
      );
      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _values.applyParsed(parsed);
      });
    });
  }

  Future<void> _save() async {
    final title = _parsed.title.isNotEmpty ? _parsed.title : _input.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final fields = composeTaskFields(
      parsed: _parsed,
      priority: _values.priority,
      dueDate: _values.dueDate,
      dueTime: _values.dueTime,
      estimate: _values.estimate,
      recurrence: _values.recurrence,
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
    final id = _values.projectId;
    if (id == null) return 'Inbox';
    for (final project in widget.projects) {
      if (project.id == id) return project.name;
    }
    return 'Project';
  }

  /// Where a menu should open: anchored to the control that asked for it.
  ///
  /// `showMenu` requires exactly one of `position`/`positionBuilder`; without
  /// one it dereferences a null position and the screen goes blank.
  RelativeRect _menuPosition(BuildContext anchorContext) {
    final box = anchorContext.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(anchorContext).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    return RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlay.size,
    );
  }

  /// The line under the input: what the line was understood to mean.
  List<Widget> _preview(ThemeData theme) {
    Widget chip(String label, IconData icon, {bool muted = false}) => Chip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          avatar: Icon(icon, size: 14, color: muted ? theme.colorScheme.onSurfaceVariant : null),
          label: Text(label),
          labelStyle: muted
              ? theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)
              : null,
          side: muted ? BorderSide(color: theme.colorScheme.outlineVariant) : null,
        );

    final recognised = [
      for (final label in _parsed.chips) chip(label, Icons.auto_awesome),
      // A `#name` that matched no project stays in the title; say so instead of
      // silently ignoring it.
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
            ? 'Type a task — "call Sam tomorrow 3pm p1 +30"'
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                      decoration: const InputDecoration(hintText: 'New task', border: InputBorder.none),
                      style: theme.textTheme.titleMedium,
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_upward),
                    tooltip: 'Add task',
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _preview(theme)),
              ),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ChipButton(
                    icon: Icons.event,
                    label: _values.dueDate ?? 'Date',
                    active: _values.dueDate != null,
                    onTap: (_) => _pickDate(),
                    onClear: _values.dueDate == null
                        ? null
                        : () => setState(() {
                              _values.dueDate = null;
                              _values.dueTime = null;
                              _values.release('due');
                            }),
                  ),
                  _ChipButton(
                    icon: Icons.schedule,
                    label: _values.dueTime ?? 'Time',
                    active: _values.dueTime != null,
                    onTap: (_) => _pickTime(),
                    onClear: _values.dueTime == null
                        ? null
                        : () => setState(() {
                              _values.dueTime = null;
                              _values.release('due');
                            }),
                  ),
                  _ChipButton(
                    icon: Icons.timelapse,
                    label: _estimateText,
                    active: _values.estimate != null,
                    onTap: (anchor) => _showDurationMenu(anchor),
                    onClear: _values.estimate == null
                        ? null
                        : () => setState(() {
                              _values.estimate = null;
                              _values.release('estimate');
                            }),
                  ),
                  _ChipButton(
                    icon: Icons.repeat,
                    label: _values.recurrence ?? 'Repeat',
                    active: _values.recurrence != null,
                    onTap: (anchor) => _showRepeatMenu(anchor),
                    onClear: _values.recurrence == null
                        ? null
                        : () => setState(() {
                              _values.recurrence = null;
                              _values.release('recurrence');
                            }),
                  ),
                  _ChipButton(
                    icon: Icons.flag,
                    label: _values.priority < 4 ? 'P${_values.priority}' : 'Priority',
                    active: _values.priority < 4,
                    onTap: (anchor) => _showPriorityMenu(anchor),
                    onClear: _values.priority < 4
                        ? () => setState(() {
                              _values.priority = 4;
                              _values.release('priority');
                            })
                        : null,
                  ),
                  _ChipButton(
                    icon: Icons.folder,
                    label: _projectName,
                    active: _values.projectId != null,
                    onTap: (anchor) => _showProjectMenu(anchor),
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final current = _values.dueDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current == null ? now : DateTime.tryParse(current) ?? now,
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

  Future<void> _showDurationMenu(BuildContext anchor) async {
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

  Future<void> _showRepeatMenu(BuildContext anchor) async {
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

  Future<void> _showPriorityMenu(BuildContext anchor) async {
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

  Future<void> _showProjectMenu(BuildContext anchor) async {
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

/// A control that shows its value, opens a menu anchored to itself, and clears
/// when long-pressed.
class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClear,
  });

  final IconData icon;
  final String label;
  final bool active;
  final void Function(BuildContext anchor) onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Builder(
      // A context whose render object is the chip itself, so an opened menu is
      // placed against the control that asked for it.
      builder: (anchor) => InkWell(
        onTap: () => onTap(anchor),
        onLongPress: onClear,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: active ? theme.colorScheme.secondaryContainer : null,
            border: Border.all(
              color: active ? Colors.transparent : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: active ? theme.colorScheme.onSecondaryContainer : null),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: active ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
