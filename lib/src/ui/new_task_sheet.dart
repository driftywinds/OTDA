import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../quickadd_bridge.dart';

/// The composer behind the plus button: one line to type, a preview of what the
/// line was understood to mean, and the date, time, duration, repeat, priority
/// and project within reach.
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

  ParsedLine _parsed = const ParsedLine(title: '');
  String? _dueDate;
  String? _dueTime;
  int? _estimate;
  String? _recurrence;
  int _priority = 4;
  String? _projectId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _projectId = widget.initialProjectId;
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
        _adopt(parsed.fields);
      });
    });
  }

  /// Takes what the line set for fields the person has not set by hand.
  void _adopt(Map<String, Object?> fields) {
    final due = fields['due'];
    if (due is Map && _dueDate == null) {
      _dueDate = due['date']?.toString();
      _dueTime = due['time']?.toString();
    }
    final estimate = fields['estimate_minutes'];
    if (estimate is num && _estimate == null) _estimate = estimate.toInt();
    final recurrence = fields['recurrence'];
    if (recurrence is String && recurrence.isNotEmpty && _recurrence == null) _recurrence = recurrence;
    final priority = fields['priority'];
    if (priority is num && _priority == 4) _priority = priority.toInt();
    final project = fields['project_id'];
    if (project is String && _projectId == null) _projectId = project;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate == null ? now : DateTime.tryParse(_dueDate!) ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
    );
    if (picked == null) return;
    setState(() {
      _dueDate = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _pickTime() async {
    final parts = (_dueTime ?? '09:00').split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.tryParse(parts.first) ?? 9, minute: int.tryParse(parts.last) ?? 0),
    );
    if (picked == null) return;
    setState(() {
      _dueTime = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      _dueDate ??= todayString();
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
    if (value == null || value.trim().isEmpty) return;
    setState(() => apply(value.trim()));
  }

  Future<void> _save() async {
    final title = _parsed.title.isNotEmpty ? _parsed.title : _input.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final fields = composeTaskFields(
      parsed: _parsed,
      dueDate: _dueDate,
      dueTime: _dueTime,
      estimate: _estimate,
      recurrence: _recurrence,
      priority: _priority,
      projectId: _projectId,
    );
    await widget.repo.createTask(title, projectId: _projectId, extra: fields);
    if (mounted) Navigator.of(context).pop(true);
  }

  String get _estimateText {
    final minutes = _estimate;
    if (minutes == null) return 'Duration';
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
  }

  String get _projectName {
    if (_projectId == null) return 'Inbox';
    for (final project in widget.projects) {
      if (project.id == _projectId) return project.name;
    }
    return 'Project';
  }

  /// The line under the input: what the line was understood to mean.
  List<Widget> _preview(ThemeData theme) {
    Widget chip(String label, IconData icon) => Chip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          avatar: Icon(icon, size: 14),
          label: Text(label),
        );

    if (_parsed.chips.isNotEmpty) {
      return [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [for (final label in _parsed.chips) chip(label, Icons.auto_awesome)],
        ),
      ];
    }

    final chosen = <Widget>[
      if (_dueDate != null) chip([_dueDate, ?_dueTime].join(' '), Icons.event),
      if (_estimate != null) chip(_estimateText, Icons.timelapse),
      if (_recurrence != null) chip(_recurrence!, Icons.repeat),
      if (_priority < 4) chip('P$_priority', Icons.flag),
      if (_projectId != null) chip(_projectName, Icons.folder),
    ];
    if (chosen.isNotEmpty) return [Wrap(spacing: 6, runSpacing: 4, children: chosen)];

    return [
      Text(
        _input.text.trim().isEmpty
            ? 'Type a task — "call Sam tomorrow 3pm p1 #work 30m"'
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
                      decoration: const InputDecoration(
                        hintText: 'New task',
                        border: InputBorder.none,
                      ),
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
                    label: _dueDate ?? 'Date',
                    active: _dueDate != null,
                    onTap: _pickDate,
                    onClear: _dueDate == null ? null : () => setState(() {
                      _dueDate = null;
                      _dueTime = null;
                    }),
                  ),
                  _ChipButton(
                    icon: Icons.schedule,
                    label: _dueTime ?? 'Time',
                    active: _dueTime != null,
                    onTap: _pickTime,
                    onClear: _dueTime == null ? null : () => setState(() => _dueTime = null),
                  ),
                  _ChipButton(
                    icon: Icons.timelapse,
                    label: _estimateText,
                    active: _estimate != null,
                    onTap: () => _showDurationMenu(context),
                    onClear: _estimate == null ? null : () => setState(() => _estimate = null),
                  ),
                  _ChipButton(
                    icon: Icons.repeat,
                    label: _recurrence ?? 'Repeat',
                    active: _recurrence != null,
                    onTap: () => _showRepeatMenu(context),
                    onClear: _recurrence == null ? null : () => setState(() => _recurrence = null),
                  ),
                  _ChipButton(
                    icon: Icons.flag,
                    label: _priority < 4 ? 'P$_priority' : 'Priority',
                    active: _priority < 4,
                    onTap: () => _showPriorityMenu(context),
                    onClear: _priority < 4 ? () => setState(() => _priority = 4) : null,
                  ),
                  _ChipButton(
                    icon: Icons.folder,
                    label: _projectName,
                    active: _projectId != null,
                    onTap: () => _showProjectMenu(context),
                    onClear: _projectId == null ? null : () => setState(() => _projectId = null),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDurationMenu(BuildContext context) async {
    const presets = [15, 30, 45, 60, 90, 120, 180, 240];
    final choice = await showMenu<int>(
      context: context,
      items: [
        for (final minutes in presets)
          PopupMenuItem(value: minutes, child: Text(_durationLabel(minutes))),
      ],
    );
    if (choice != null) setState(() => _estimate = choice);
  }

  static String _durationLabel(int minutes) =>
      minutes < 60 ? '${minutes}m' : (minutes % 60 == 0 ? '${minutes ~/ 60}h' : '${minutes ~/ 60}h ${minutes % 60}m');

  Future<void> _showRepeatMenu(BuildContext context) async {
    const presets = ['every day', 'every weekday', 'every week', 'every month', 'every year'];
    final choice = await showMenu<String>(
      context: context,
      items: [
        for (final rule in presets) PopupMenuItem(value: rule, child: Text(rule)),
        const PopupMenuItem(value: '__custom', child: Text('Custom…')),
      ],
    );
    if (choice == null) return;
    if (choice == '__custom') {
      await _pickCustom('Repeat', _recurrence ?? 'every week', (value) => _recurrence = value);
    } else {
      setState(() => _recurrence = choice);
    }
  }

  Future<void> _showPriorityMenu(BuildContext context) async {
    final choice = await showMenu<int>(
      context: context,
      items: const [
        PopupMenuItem(value: 1, child: Text('P1 — highest')),
        PopupMenuItem(value: 2, child: Text('P2')),
        PopupMenuItem(value: 3, child: Text('P3')),
        PopupMenuItem(value: 4, child: Text('P4 — default')),
      ],
    );
    if (choice != null) setState(() => _priority = choice);
  }

  Future<void> _showProjectMenu(BuildContext context) async {
    final choice = await showMenu<String?>(
      context: context,
      items: [
        const PopupMenuItem<String?>(value: null, child: Text('Inbox')),
        for (final project in widget.projects)
          if (!project.isDeleted && !project.isArchived)
            PopupMenuItem<String?>(value: project.id, child: Text(project.name)),
      ],
    );
    if (choice != null) setState(() => _projectId = choice);
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
    // Everything else the line set (labels, start, sector, reminders…).
    for (final entry in parsed.fields.entries)
      if (!const {'due', 'priority', 'estimate_minutes', 'recurrence', 'project_id'}
          .contains(entry.key))
        entry.key: entry.value,
  };
}

/// A control that shows its value, opens a picker, and clears when long-pressed.
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
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
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
    );
  }
}
