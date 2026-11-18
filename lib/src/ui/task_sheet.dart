import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/repo.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dueText = _due == null
        ? 'No date'
        : [_due!['date'], if (_due!['time'] != null) _due!['time']].join(' ');

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: _completed,
                    shape: const CircleBorder(),
                    onChanged: (value) async {
                      setState(() => _completed = value ?? false);
                      await widget.repo.setCompleted(widget.task, _completed);
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: _title,
                      style: theme.textTheme.titleMedium,
                      decoration: const InputDecoration(border: InputBorder.none, hintText: 'Title'),
                      onSubmitted: (_) => _saveTitle(),
                      onTapOutside: (_) => _saveTitle(),
                    ),
                  ),
                ],
              ),
              const Divider(),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.event, size: 16),
                    label: Text(dueText),
                    onPressed: _pickDate,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.schedule, size: 16),
                    label: const Text('Time'),
                    onPressed: _pickTime,
                  ),
                  if (_due != null)
                    ActionChip(
                      avatar: const Icon(Icons.close, size: 16),
                      label: const Text('Clear date'),
                      onPressed: _clearDue,
                    ),
                  PopupMenuButton<int>(
                    initialValue: _priority,
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
                    child: Chip(
                      avatar: const Icon(Icons.flag, size: 16),
                      label: Text('P$_priority'),
                    ),
                  ),
                  PopupMenuButton<String?>(
                    initialValue: _projectId,
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
                    child: Chip(
                      avatar: const Icon(Icons.folder, size: 16),
                      label: Text(_projectId == null
                          ? 'Inbox'
                          : widget.projects
                              .where((p) => p.id == _projectId)
                              .map((p) => p.name)
                              .firstOrNull ??
                              'Project'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                minLines: 3,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'Notes', alignLabelWithHint: true),
                onTapOutside: (_) => _saveNotes(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await widget.repo.trash(widget.task);
                      if (context.mounted) Navigator.of(context).pop(true);
                    },
                    icon: const Icon(Icons.delete_outline),
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
            ],
          ),
        ),
      ),
    );
  }
}
