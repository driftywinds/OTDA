import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../e2ee/attachments.dart';
import '../e2ee/session.dart';
import '../quickadd/rule.dart' as rules;
import '../reminders/service.dart';
import 'format.dart';
import 'new_task_sheet.dart';
import 'repeat_sheet.dart';
import 'task_history_screen.dart';
import 'task_page_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// One task, editable: the fields the API takes, written as ops as you change
/// them, so the sheet works offline and never blocks on the network.
class TaskSheet extends StatefulWidget {
  const TaskSheet({
    super.key,
    required this.task,
    required this.repo,
    required this.projects,
    this.authorId = '',
  });

  final Task task;
  final Repo repo;
  final List<Project> projects;
  final String authorId;

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
  late String? _deadline = widget.task.deadline;

  /// Null, `someday` or `YYYY-MM-DD`.
  late String? _start = switch (widget.task.raw['start']?.toString()) {
    null || '' => null,
    final value => value,
  };
  late int? _estimate = widget.task.estimateMinutes;

  /// `""`, `deep`, `medium` or `low`.
  late String _energy = widget.task.raw['energy']?.toString() ?? '';
  late List<String> _labels = [...widget.task.labels];
  late String? _sectionId = widget.task.sectionId;
  List<Label> _allLabels = const [];
  List<Section> _sections = const [];
  int _subtaskDone = 0;
  int _subtaskTotal = 0;

  /// The repeat rule as stored (`every month`, `every 3 days after completion`),
  /// empty for a one-off task.
  late String _recurrence = widget.task.raw['recurrence']?.toString() ?? '';

  bool _attachmentsBusy = false;
  List<Attachment> _attachments = const [];

  @override
  void initState() {
    super.initState();
    _loadLabels();
    _loadSections();
    _loadProgress();
    _loadAttachments();
  }

  AttachmentService? get _attachmentService {
    final client = widget.repo.engine.client;
    if (widget.authorId.isEmpty) return null;
    return AttachmentService(repo: widget.repo, client: client, authorId: widget.authorId);
  }

  Future<void> _loadAttachments() async {
    final items = await widget.repo.attachments(widget.task.id);
    if (!mounted) return;
    setState(() => _attachments = items);
  }

  Future<void> _loadProgress() async {
    final progress = await widget.repo.subtaskProgress(widget.task.id);
    if (!mounted) return;
    setState(() {
      _subtaskDone = progress.done;
      _subtaskTotal = progress.total;
    });
  }

  Future<void> _loadLabels() async {
    final labels = await widget.repo.labels();
    if (!mounted) return;
    setState(() {
      _allLabels = labels;
      _labels = [
        for (final id in _labels)
          if (labels.any((label) => label.id == id)) id,
      ];
    });
  }

  Future<void> _loadSections() async {
    final projectId = _projectId;
    if (projectId == null) {
      if (mounted) setState(() => _sections = const []);
      return;
    }
    final sections = await widget.repo.sections(projectId);
    if (!mounted) return;
    setState(() {
      _sections = sections;
      if (_sectionId != null && !sections.any((s) => s.id == _sectionId)) _sectionId = null;
    });
  }

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

  /// The repeat sheet is the one place for the four fields people change together:
  /// the time, the reminder, the rule and how the series ends.
  Future<void> _pickRepeat() async {
    final today = _todayIso();
    final reminder = await ReminderService.instance.reminderOffset(widget.task.id);
    if (!mounted) return;
    final result = await showRepeatSheet(
      context,
      task: widget.task,
      today: today,
      due: _due,
      recurrence: _recurrence,
      reminderMinutes: reminder,
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (result.rule != _recurrence) {
        await _setRecurrence(result.rule);
      }
      if (!_sameDue(result.due, _due)) {
        await widget.repo.setField('task', widget.task.id, 'due', result.due);
        setState(() => _due = result.due);
      }
      if (result.reminderMinutes != reminder) {
        await ReminderService.instance.setReminderOffset(widget.task.id, result.reminderMinutes);
      }
      await refreshTaskSurfaces(widget.repo);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  bool _sameDue(Map<String, Object?>? a, Map<String, Object?>? b) {
    if (a == null || b == null) return a == b;
    return a['date'] == b['date'] && a['time'] == b['time'];
  }

  String _todayIso() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _setRecurrence(String rule) async {
    if (rule.isEmpty) {
      await widget.repo.setField('task', widget.task.id, 'recurrence', null);
      if (mounted) setState(() => _recurrence = '');
      return;
    }
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

  /// The same day picker the due date uses, returning `YYYY-MM-DD` or null.
  Future<String?> _pickDay(String? current) async {
    final now = DateTime.now();
    final initial = current != null ? DateTime.tryParse(current) ?? now : now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return null;
    return '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDeadline() async {
    final date = await _pickDay(_deadline);
    if (date == null) return;
    await widget.repo.setField('task', widget.task.id, 'deadline', date);
    if (mounted) setState(() => _deadline = date);
  }

  Future<void> _clearDeadline() async {
    await widget.repo.setField('task', widget.task.id, 'deadline', null);
    if (mounted) setState(() => _deadline = null);
  }

  Future<void> _pickStart() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('No start date'),
              trailing: _start == null ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop('__none'),
            ),
            ListTile(
              title: const Text('Someday'),
              subtitle: const Text('Parked until you move it'),
              trailing: _start == 'someday' ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop('someday'),
            ),
            ListTile(
              leading: const Icon(Icons.event_available_outlined),
              title: Text(_start != null && _start != 'someday' ? 'Change date' : 'Pick a date…'),
              onTap: () => Navigator.of(context).pop('__date'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    String? value;
    if (choice == '__date') {
      value = await _pickDay(_start != 'someday' ? _start : null);
      if (value == null) return;
    } else {
      value = choice == '__none' ? null : choice;
    }
    await widget.repo.setField('task', widget.task.id, 'start', value);
    if (mounted) setState(() => _start = value);
  }

  Future<void> _pickEstimate() async {
    const presets = [15, 30, 45, 60, 90, 120, 240];
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('No estimate'),
                trailing: _estimate == null ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(context).pop('__none'),
              ),
              for (final minutes in presets)
                ListTile(
                  title: Text(durationLabel(minutes)),
                  trailing: _estimate == minutes ? const Icon(Icons.check_rounded) : null,
                  onTap: () => Navigator.of(context).pop('$minutes'),
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Custom minutes…'),
                onTap: () => Navigator.of(context).pop('__custom'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    int? minutes;
    if (choice == '__custom') {
      final controller = TextEditingController(text: _estimate?.toString() ?? '');
      final typed = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Estimate'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Minutes', suffixText: 'min'),
            onSubmitted: (text) => Navigator.of(context).pop(text),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Set')),
          ],
        ),
      );
      controller.dispose();
      if (typed == null) return;
      minutes = int.tryParse(typed.trim());
      if (minutes == null || minutes < 1 || minutes > 10080) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Use a whole number of minutes, up to one week.')),
          );
        }
        return;
      }
    } else if (choice != '__none') {
      minutes = int.tryParse(choice);
    }
    await widget.repo.setField('task', widget.task.id, 'estimate_minutes', minutes);
    if (mounted) setState(() => _estimate = minutes);
  }

  Future<void> _setEnergy(String energy) async {
    final value = energy.isEmpty ? null : energy;
    await widget.repo.setField('task', widget.task.id, 'energy', value ?? '');
    if (mounted) setState(() => _energy = value ?? '');
  }

  String _labelNames(List<String> ids) {
    final names = [
      for (final id in ids)
        if (_allLabels.where((label) => label.id == id).firstOrNull != null)
          _allLabels.where((label) => label.id == id).first.name,
    ];
    if (names.isEmpty) return 'Labels';
    return names.length <= 2 ? names.join(', ') : '${names.take(2).join(', ')} +${names.length - 2}';
  }

  Future<void> _setLabels(List<String> ids) async {
    await widget.repo.setField('task', widget.task.id, 'labels', ids);
    if (mounted) setState(() => _labels = [...ids]);
  }

  Future<void> _editLabels() async {
    final selected = {..._labels};
    final added = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: added,
                          decoration: const InputDecoration(
                            hintText: 'New label by name',
                            prefixIcon: Icon(Icons.new_label_outlined),
                          ),
                          onSubmitted: (text) async {
                            final name = text.trim();
                            if (name.isEmpty) return;
                            final id = await widget.repo.ensureLabel(name);
                            if (!context.mounted) return;
                            selected.add(id);
                            added.clear();
                            await _setLabels(selected.toList());
                            await _loadLabels();
                            setSheetState(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Create label',
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () async {
                          final name = added.text.trim();
                          if (name.isEmpty) return;
                          final id = await widget.repo.ensureLabel(name);
                          if (!context.mounted) return;
                          selected.add(id);
                          added.clear();
                          await _setLabels(selected.toList());
                          await _loadLabels();
                          setSheetState(() {});
                        },
                      ),
                    ],
                  ),
                ),
                if (_allLabels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No labels yet. Type a name above to make one.'),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final label in _allLabels)
                          CheckboxListTile(
                            value: selected.contains(label.id),
                            title: Text(label.name),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (on) async {
                              setSheetState(() {
                                if (on == true) {
                                  selected.add(label.id);
                                } else {
                                  selected.remove(label.id);
                                }
                              });
                              await _setLabels(selected.toList());
                            },
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    added.dispose();
  }

  Future<void> _setSection(String? id) async {
    await widget.repo.setField('task', widget.task.id, 'section_id', id);
    if (mounted) setState(() => _sectionId = id);
  }

  Future<void> _addSubtask() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => NewTaskSheet(
        repo: widget.repo,
        projects: widget.projects,
        initialParent: widget.task,
      ),
    );
    if (saved == true) await _loadProgress();
  }

  Future<void> _addFiles() async {
    final service = _attachmentService;
    if (service == null || _attachmentsBusy) return;
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty || !mounted) return;
    setState(() => _attachmentsBusy = true);
    try {
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final mime = lookupMimeType(file.name, headerBytes: bytes) ?? 'application/octet-stream';
        await service.add(taskId: widget.task.id, name: file.name, mime: mime, bytes: bytes);
      }
      await _loadAttachments();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(picked.length == 1 ? 'File attached.' : '${picked.length} files attached.')),
        );
      }
    } on AttachmentError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on Object catch (e) {
      if (mounted) {
        final message = e is Exception && e.toString().contains('attachments_disabled')
            ? 'Attachments are turned off on this server.'
            : 'The file could not be attached: $e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _attachmentsBusy = false);
    }
  }

  Future<void> _openAttachment(Attachment attachment) async {
    final service = _attachmentService;
    if (service == null) return;
    if (attachment.isLink) {
      await SharePlus.instance.share(ShareParams(text: attachment.url));
      return;
    }
    setState(() => _attachmentsBusy = true);
    try {
      if (attachment.uploadedAt == null) {
        await service.upload(attachment.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Uploaded. The server confirms it on the next sync.')),
          );
        }
        return;
      }
      final opened = await service.open(attachment);
      final file = await service.materialize(opened);
      if (!mounted) return;
      if (opened.mime.startsWith('image/')) {
        await showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.file(File(file.path), fit: BoxFit.contain),
            ),
          ),
        );
      } else {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path, mimeType: opened.mime)], subject: opened.name),
        );
      }
    } on AttachmentError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on Object catch (e) {
      if (mounted) {
        final message = e is Exception && e.toString().contains('attachments_disabled')
            ? 'Attachments are turned off on this server.'
            : 'The file could not be opened: $e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _attachmentsBusy = false);
    }
  }

  Future<void> _removeAttachment(Attachment attachment) async {
    final service = _attachmentService;
    if (service == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this file?'),
        content: Text(attachment.name),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await service.remove(attachment);
    await _loadAttachments();
  }

  String _attachmentState(Attachment attachment) {
    if (attachment.isLink) return 'Link';
    if (attachment.encrypted && !E2eeSession.instance.unlocked) return 'Encrypted · unlock to open';
    if (attachment.uploadedAt == null) return 'Uploading · tap to retry';
    final kb = attachment.size / 1024;
    return attachment.encrypted ? '${_sizeLabel(kb)} · encrypted' : _sizeLabel(kb);
  }

  static String _sizeLabel(double kb) => kb < 1024 ? '${kb.round()} KB' : '${(kb / 1024).toStringAsFixed(1)} MB';

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
    final sectionName = _sections.where((s) => s.id == _sectionId).firstOrNull?.name;

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
                        await refreshTaskSurfaces(widget.repo);
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Done for now — it comes round again')),
                        );
                        return;
                      }
                      setState(() => _completed = !_completed);
                      await widget.repo.setCompleted(widget.task, _completed);
                      await refreshTaskSurfaces(widget.repo);
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
                      icon: Icons.outlined_flag_rounded,
                      label: _deadline == null ? 'Deadline' : 'Due by ${friendlyDate(_deadline!, today)}',
                      active: _deadline != null,
                      onTap: _pickDeadline,
                      onClear: _deadline == null ? null : _clearDeadline,
                    ),
                    PropChip(
                      icon: Icons.play_circle_outline,
                      label: _start == null
                          ? 'Start'
                          : _start == 'someday'
                              ? 'Someday'
                              : 'From ${friendlyDate(_start!, today)}',
                      active: _start != null,
                      onTap: _pickStart,
                      onClear: _start == null
                          ? null
                          : () async {
                              await widget.repo.setField('task', widget.task.id, 'start', null);
                              if (mounted) setState(() => _start = null);
                            },
                    ),
                    PropChip(
                      icon: Icons.timelapse_rounded,
                      label: _estimate == null ? 'Estimate' : durationLabel(_estimate!),
                      active: _estimate != null,
                      onTap: _pickEstimate,
                      onClear: _estimate == null
                          ? null
                          : () async {
                              await widget.repo.setField('task', widget.task.id, 'estimate_minutes', null);
                              if (mounted) setState(() => _estimate = null);
                            },
                    ),
                    PopupMenuButton<String>(
                      initialValue: _energy,
                      tooltip: 'Energy',
                      onSelected: _setEnergy,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: '', child: Text('No energy')),
                        PopupMenuItem(value: 'deep', child: Text('Deep work')),
                        PopupMenuItem(value: 'medium', child: Text('Medium')),
                        PopupMenuItem(value: 'low', child: Text('Low')),
                      ],
                      child: PropChip(
                        icon: Icons.bolt_rounded,
                        label: switch (_energy) {
                          'deep' => 'Deep',
                          'medium' => 'Medium',
                          'low' => 'Low',
                          _ => 'Energy',
                        },
                        active: _energy.isNotEmpty,
                      ),
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
                        if (value == _projectId) return;
                        final messenger = ScaffoldMessenger.of(context);
                        setState(() => _projectId = value);
                        try {
                          // Moving a parent carries every descendant; a subtask
                          // that leaves its parent's project loses the parent.
                          await widget.repo.moveToProject(widget.task, value);
                          if (_sectionId != null) {
                            await widget.repo.setField('task', widget.task.id, 'section_id', null);
                            if (mounted) setState(() => _sectionId = null);
                          }
                          await _loadSections();
                        } on Object catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text('$e')));
                        }
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
                    if (_projectId != null)
                      PopupMenuButton<String?>(
                        initialValue: _sectionId,
                        tooltip: 'Section',
                        onSelected: _setSection,
                        itemBuilder: (_) => [
                          const PopupMenuItem<String?>(value: null, child: Text('No section')),
                          for (final section in _sections)
                            PopupMenuItem<String?>(value: section.id, child: Text(section.name)),
                        ],
                        child: PropChip(
                          icon: Icons.view_stream_outlined,
                          label: sectionName ?? 'Section',
                          active: _sectionId != null,
                        ),
                      ),
                    PropChip(
                      icon: Icons.label_outline_rounded,
                      label: _labelNames(_labels),
                      active: _labels.isNotEmpty,
                      onTap: _editLabels,
                      onClear: _labels.isEmpty ? null : () => _setLabels(const []),
                    ),
                    PropChip(
                      icon: Icons.account_tree_outlined,
                      label: _subtaskTotal == 0
                          ? 'Add subtask'
                          : '$_subtaskDone/$_subtaskTotal subtasks',
                      active: _subtaskTotal > 0,
                      onTap: _addSubtask,
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
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'ATTACHMENTS${_attachments.isEmpty ? '' : ' (${_attachments.length})'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (_attachmentService != null)
                      IconButton(
                        tooltip: 'Add a file',
                        onPressed: _attachmentsBusy ? null : _addFiles,
                        icon: _attachmentsBusy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.attach_file_rounded, size: 20),
                      ),
                  ],
                ),
              ),
              if (_attachments.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Text(
                    'No files yet.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                for (final attachment in _attachments)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      attachment.encrypted && !E2eeSession.instance.unlocked
                          ? Icons.lock_outline
                          : attachment.mime.startsWith('image/')
                              ? Icons.image_outlined
                              : attachment.isLink
                                  ? Icons.link_rounded
                                  : Icons.insert_drive_file_outlined,
                      size: 20,
                    ),
                    title: Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_attachmentState(attachment)),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: _attachmentsBusy ? null : () => _removeAttachment(attachment),
                    ),
                    onTap: _attachmentsBusy ? null : () => _openAttachment(attachment),
                  ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      onPressed: () async {
                        if (_recurrence.isEmpty) {
                          await widget.repo.trash(widget.task);
                        } else {
                          final scope = await showModalBottomSheet<SeriesScope>(
                            context: context,
                            showDragHandle: true,
                            builder: (context) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    title: Text(
                                      'This is a repeating task',
                                      style: Theme.of(context).textTheme.titleSmall,
                                    ),
                                    subtitle: Text(_recurrenceLabel(_recurrence)),
                                  ),
                                  const Divider(height: 1),
                                  ListTile(
                                    leading: const Icon(Icons.event_busy_outlined),
                                    title: const Text('This occurrence'),
                                    subtitle: const Text('Skip today; it comes round again'),
                                    onTap: () => Navigator.of(context).pop(SeriesScope.occurrence),
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.event_repeat_outlined),
                                    title: const Text('This and future occurrences'),
                                    subtitle: const Text('The past stays as history'),
                                    onTap: () => Navigator.of(context).pop(SeriesScope.future),
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.delete_forever_outlined),
                                    title: const Text('All occurrences, past and future'),
                                    onTap: () => Navigator.of(context).pop(SeriesScope.all),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          );
                          if (scope == null) return;
                          await widget.repo.deleteSeries(widget.task, scope);
                        }
                        if (context.mounted) Navigator.of(context).pop(true);
                      },
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Delete'),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TaskPageScreen(repo: widget.repo, task: widget.task),
                        ),
                      ),
                      icon: const Icon(Icons.public_rounded),
                      label: const Text('Share page'),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TaskHistoryScreen(task: widget.task, repo: widget.repo),
                        ),
                      ),
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('History'),
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
