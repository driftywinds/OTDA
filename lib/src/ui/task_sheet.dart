import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../quickadd/rule.dart' as rules;
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// One task, editable: the fields the API takes, written as ops as you change
/// them, so the sheet works offline and never blocks on the network.
class TaskSheet extends StatefulWidget {
  const TaskSheet({super.key, required this.task, required this.repo, required this.projects});

  final Task task;
  final Repo repo;
  final List<Project> projects;

  @override
  State<TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends State<TaskSheet> {
  late final TextEditingController _title = TextEditingController(text: widget.task.title);
  late final TextEditingController _notes =
      TextEditingController(text: widget.task.raw['description']?.toString() ?? '');
  late bool _completed = widget.task.isCompleted;
  late int _priority = widget.task.priority;
  late String? _projectId = widget.task.projectId;
  late Map<String, Object?>? _due = widget.task.due;

  /// The repeat rule as stored (`every month`, `every 3 days after completion`),
  /// empty for a one-off task.
  late String _recurrence = widget.task.raw['recurrence']?.toString() ?? '';

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _saveTitle() async {
    final text = _title.text.trim();
    if (text.isEmpty || text == widget.task.title) return;
    await widget.repo.setField('task', widget.task.id, 'title', text);
  }

  Future<void> _saveNotes() async {
    final text = _notes.text;
    if (text == (widget.task.raw['description']?.toString() ?? '')) return;
    await widget.repo.setField('task', widget.task.id, 'description', text);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _due?['date'] != null ? DateTime.tryParse(_due!['date'].toString()) ?? now : now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return;
    final date =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    final keepTime = _due?['time'];
    final value = <String, Object?>{'date': date, 'time': ?keepTime};
    await widget.repo.setField('task', widget.task.id, 'due', value);
    setState(() => _due = value);
  }

  static String _recurrenceLabel(String rule) {
    final parsed = rules.parseRule(rule);
    return parsed.ok ? (parsed.canonical ?? rule) : rule;
  }

  /// Presets plus a field for any rule the grammar accepts, the same shapes the
  /// composer offers: `every month`, `every 3 days after completion`, …
  Future<void> _pickRepeat() async {
    const presets = ['every day', 'every weekday', 'every week', 'every month', 'every year'];
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final rule in presets)
              ListTile(
                title: Text(rule),
                trailing: rule == _recurrence ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(context).pop(rule),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(_recurrence.isEmpty ? 'Custom rule…' : 'Edit “$_recurrence”…'),
              onTap: () => Navigator.of(context).pop('__custom'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == '__custom') {
      final controller = TextEditingController(text: _recurrence.isEmpty ? 'every week' : _recurrence);
      final typed = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Repeat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'every 2nd tuesday'),
            onSubmitted: (text) => Navigator.of(context).pop(text),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Set')),
          ],
        ),
      );
      controller.dispose();
      if (typed == null || !mounted) return;
      final rule = typed.trim();
      if (rule.isEmpty) return;
      if (!rules.parseRule(rule).ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That is not a rule this app understands.')),
        );
        return;
      }
      await _setRecurrence(rule);
      return;
    }
    await _setRecurrence(choice);
  }

  Future<void> _setRecurrence(String rule) async {
    final canonical = rules.parseRule(rule).canonical ?? rule;
    await widget.repo.setField('task', widget.task.id, 'recurrence', canonical);
    if (mounted) setState(() => _recurrence = canonical);
  }

  Future<void> _clearRepeat() async {
    await widget.repo.setField('task', widget.task.id, 'recurrence', null);
    if (mounted) setState(() => _recurrence = '');
  }

  Future<void> _pickTime() async {
    if (_due == null) {
      await _pickDate();
      if (!mounted || _due == null) return;
    }
    final current = _due!['time']?.toString();
    final parts = (current ?? '09:00').split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.tryParse(parts.first) ?? 9, minute: int.tryParse(parts.last) ?? 0),
    );
    if (picked == null) return;
    final time = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    final value = <String, Object?>{'date': _due!['date'], 'time': time};
    await widget.repo.setField('task', widget.task.id, 'due', value);
    setState(() => _due = value);
  }

  Future<void> _clearDue() async {
    await widget.repo.setField('task', widget.task.id, 'due', null);
    setState(() => _due = null);
  }

  String get _projectName {
    if (_projectId == null) return 'Inbox';
    for (final project in widget.projects) {
      if (project.id == _projectId) return project.name;
    }
    return 'Project';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final today = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final date = _due?['date']?.toString();
    final time = _due?['time']?.toString();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaskCheck(
                    done: _completed,
                    priority: _priority,
                    onChanged: () async {
                      // Ticking a repeating task finishes one occurrence: the
                      // series stays open and comes round again, so the tick must
                      // not stick here.
                      if (_recurrence.isNotEmpty) {
                        if (_completed) return;
                        final messenger = ScaffoldMessenger.of(context);
                        await widget.repo.setCompleted(widget.task, true);
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Done for now — it comes round again')),
                        );
                        return;
                      }
                      setState(() => _completed = !_completed);
                      await widget.repo.setCompleted(widget.task, _completed);
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: _title,
                      minLines: 1,
                      maxLines: 4,
                      style: theme.textTheme.titleLarge?.copyWith(
                        decoration: _completed ? TextDecoration.lineThrough : null,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        hintText: 'Title',
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      onSubmitted: (_) => _saveTitle(),
                      onTapOutside: (_) => _saveTitle(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PropChip(
                      icon: Icons.event_rounded,
                      label: date == null ? 'Date' : friendlyDate(date, today),
                      active: date != null,
                      onTap: _pickDate,
                      onClear: date == null ? null : _clearDue,
                    ),
                    PropChip(
                      icon: Icons.schedule_rounded,
                      label: time ?? 'Time',
                      active: time != null,
                      onTap: _pickTime,
                    ),
                    PropChip(
                      icon: Icons.repeat_rounded,
                      label: _recurrence.isEmpty ? 'Repeat' : _recurrenceLabel(_recurrence),
                      active: _recurrence.isNotEmpty,
                      onTap: _pickRepeat,
                      onClear: _recurrence.isEmpty ? null : _clearRepeat,
                    ),
                    PopupMenuButton<int>(
                      initialValue: _priority,
                      tooltip: 'Priority',
                      onSelected: (value) async {
                        setState(() => _priority = value);
                        await widget.repo.setField('task', widget.task.id, 'priority', value);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 1, child: Text('Priority 1')),
                        PopupMenuItem(value: 2, child: Text('Priority 2')),
                        PopupMenuItem(value: 3, child: Text('Priority 3')),
                        PopupMenuItem(value: 4, child: Text('Priority 4 (default)')),
                      ],
                      child: PropChip(
                        icon: Icons.flag_rounded,
                        label: _priority < 4 ? 'P$_priority' : 'Priority',
                        active: _priority < 4,
                        color: priorityColor(_priority, scheme),
                      ),
                    ),
                    PopupMenuButton<String?>(
                      initialValue: _projectId,
                      tooltip: 'Project',
                      onSelected: (value) async {
                        setState(() => _projectId = value);
                        await widget.repo.setField('task', widget.task.id, 'project_id', value);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem<String?>(value: null, child: Text('Inbox')),
                        for (final project in widget.projects)
                          if (!project.isDeleted && !project.isArchived)
                            PopupMenuItem<String?>(value: project.id, child: Text(project.name)),
                      ],
                      child: PropChip(
                        icon: Icons.folder_outlined,
                        label: _projectName,
                        active: _projectId != null,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: TextField(
                  controller: _notes,
                  minLines: 3,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    hintText: 'Notes',
                    alignLabelWithHint: true,
                    contentPadding: EdgeInsets.all(16),
                  ),
                  onTapOutside: (_) => _saveNotes(),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      onPressed: () async {
                        await widget.repo.trash(widget.task);
                        if (context.mounted) Navigator.of(context).pop(true);
                      },
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Delete'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () async {
                        await _saveTitle();
                        await _saveNotes();
                        if (context.mounted) Navigator.of(context).pop(true);
                      },
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
