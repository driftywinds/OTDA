import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../data/series.dart';
import '../e2ee/attachments.dart';
import '../e2ee/session.dart';
import '../quickadd/rule.dart' as rules;
import '../reminders/service.dart';
import 'format.dart';
import 'new_task_sheet.dart';
import 'notes_field.dart';
import 'repeat_sheet.dart';
import 'task_details.dart';
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

  /// The direct subtasks in their manual order; empty for a task with none.
  List<Task> _children = const [];

  /// The repeat rule as stored (`every month`, `every 3 days after completion`),
  /// empty for a one-off task.
  late String _recurrence = widget.task.raw['recurrence']?.toString() ?? '';

  /// A finished occurrence has no rule of its own; these carry the series it came
  /// from, so the sheet can show and edit the real rule.
  late final String? _seriesId = switch (widget.task.raw['series_id']?.toString()) {
    null || '' => null,
    final value => value,
  };
  Map<String, Object?>? _seriesDue;
  bool _seriesLoaded = false;

  bool _attachmentsBusy = false;
  List<Attachment> _attachments = const [];

  @override
  void initState() {
    super.initState();
    _loadLabels();
    _loadSections();
    _loadProgress();
    _loadAttachments();
    if (_seriesId == null) {
      _seriesLoaded = true;
    } else {
      _loadSeries();
    }
  }

  Future<void> _loadSeries() async {
    final id = _seriesId;
    if (id == null) return;
    final row = await widget.repo.db.entity('task', id);
    if (!mounted) return;
    setState(() {
      _seriesDue = row?['due'] is Map ? Map<String, Object?>.from(row!['due'] as Map) : null;
      if (_recurrence.isEmpty) {
        _recurrence = row?['recurrence']?.toString() ?? '';
      }
      _seriesLoaded = true;
    });
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
    final children = [
      for (final child in await widget.repo.childrenOf(widget.task.id))
        if (!child.isDeleted) child,
    ];
    if (!mounted) return;
    setState(() {
      _children = children;
      _subtaskDone = children.where((c) => c.isCompleted).length;
      _subtaskTotal = children.length;
    });
  }

  Future<void> _toggleChild(Task child) async {
    final repeats = (child.raw['recurrence']?.toString() ?? '').isNotEmpty;
    if (repeats) {
      // Ticking a repeating subtask finishes one occurrence; it comes round again.
      if (child.isCompleted) return;
      final messenger = ScaffoldMessenger.of(context);
      await widget.repo.setCompleted(child, true);
      await refreshTaskSurfaces(widget.repo);
      messenger.showSnackBar(const SnackBar(content: Text('Done for now — it comes round again')));
    } else {
      await widget.repo.setCompleted(child, !child.isCompleted);
      await refreshTaskSurfaces(widget.repo);
    }
    await _loadProgress();
  }

  Future<void> _editChild(Task child) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => TaskSheet(
        task: child,
        repo: widget.repo,
        projects: widget.projects,
        authorId: widget.authorId,
      ),
    );
    await _loadProgress();
  }

  /// A long-press on a subtask's handle drags it; the new order is written as
  /// positions, which is what every list orders subtasks by. `onReorderItem`
  /// already adjusts the target index for the removed row.
  Future<void> _reorderChildren(int oldIndex, int newIndex) async {
    if (newIndex == oldIndex) return;
    final moved = [..._children];
    moved.insert(newIndex, moved.removeAt(oldIndex));
    setState(() => _children = moved);
    for (var i = 0; i < moved.length; i++) {
      final current = (moved[i].raw['position'] as num?)?.toDouble();
      if (current != i.toDouble()) {
        await widget.repo.setField('task', moved[i].id, 'position', i.toDouble());
      }
    }
    await refreshTaskSurfaces(widget.repo);
    await _loadProgress();
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

    // A series cannot move onto a date it has already done, skipped or moved.
    // The date is derived from its occurrence records, so this works offline.
    if (_seriesId == null && _recurrence.isNotEmpty) {
      final all = await widget.repo.tasks();
      if (!mounted) return;
      final oldDate = _due?['date']?.toString();
      if (exceptionDatesOf(widget.task.id, all).contains(date)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('${friendlyDate(date, _todayIso())} is already done for this series.')));
        return;
      }
      final shift = oldDate == null ? null : daysBetween(oldDate, date);
      await widget.repo.setField('task', widget.task.id, 'due', value);
      // The start and deadline belong to the series too. Move them by the same
      // number of days as the due date, never turning a missing field into one.
      if (shift != null && shift != 0) {
        final current = await widget.repo.task(widget.task.id);
        String? movedStart;
        String? movedDeadline;
        for (final field in ['start', 'deadline']) {
          final old = current?.raw[field]?.toString() ?? widget.task.raw[field]?.toString() ?? '';
          if (old.isEmpty || old == 'someday') continue;
          final moved = _shiftDate(old, shift);
          await widget.repo.setField('task', widget.task.id, field, moved);
          if (field == 'start') movedStart = moved;
          if (field == 'deadline') movedDeadline = moved;
        }
        if (mounted) {
          setState(() {
            if (movedStart != null) _start = movedStart;
            if (movedDeadline != null) _deadline = movedDeadline;
          });
        }
      }
      if (mounted) setState(() => _due = value);
      return;
    }

    await widget.repo.setField('task', widget.task.id, 'due', value);
    setState(() => _due = value);
  }

  static String _shiftDate(String date, int days) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return date;
    final moved = DateTime.utc(parsed.year, parsed.month, parsed.day).add(Duration(days: days));
    return '${moved.year.toString().padLeft(4, '0')}-'
        '${moved.month.toString().padLeft(2, '0')}-'
        '${moved.day.toString().padLeft(2, '0')}';
  }

  static String _recurrenceLabel(String rule) {
    final parsed = rules.parseRule(rule);
    return parsed.ok ? (parsed.canonical ?? rule) : rule;
  }

  /// The repeat sheet is the one place for the four fields people change together:
  /// the time, the reminder, the rule and how the series ends.
  Future<void> _pickRepeat() async {
    final today = _todayIso();
    final reminder = await widget.repo.taskReminderOffset(widget.task.id);
    if (!mounted) return;
    final result = await showRepeatSheet(
      context,
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
        await _setRepeatDue(result.due);
      }
      if (result.reminderMinutes != reminder) {
        await widget.repo.setTaskReminderOffset(widget.task, result.reminderMinutes);
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

  String get _repeatTargetId => _seriesId ?? widget.task.id;

  Future<void> _setRecurrence(String rule) async {
    if (rule.isEmpty) {
      await widget.repo.setField('task', _repeatTargetId, 'recurrence', null);
      if (mounted) setState(() => _recurrence = '');
      return;
    }
    final canonical = rules.parseRule(rule).canonical ?? rule;
    await widget.repo.setField('task', _repeatTargetId, 'recurrence', canonical);
    if (mounted) setState(() => _recurrence = canonical);
  }

  Future<void> _clearRepeat() async {
    await widget.repo.setField('task', _repeatTargetId, 'recurrence', null);
    if (mounted) setState(() => _recurrence = '');
  }

  /// Writes a time chosen in the repeat sheet. On a finished occurrence the date
  /// belongs to history, so only the time goes to the series, keeping the series'
  /// own (future) date.
  Future<void> _setRepeatDue(Map<String, Object?>? value) async {
    if (_seriesId == null) {
      await widget.repo.setField('task', widget.task.id, 'due', value);
      if (mounted) setState(() => _due = value);
      return;
    }
    final seriesDate = _seriesDue?['date']?.toString();
    final next = value == null
        ? null
        : <String, Object?>{
            'date': seriesDate ?? value['date'],
            'time': ?value['time'],
          };
    await widget.repo.setField('task', _seriesId, 'due', next);
    if (mounted) {
      setState(() {
        _seriesDue = next;
        _due = value;
      });
    }
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

  Future<void> _clearTime() async {
    final date = _due?['date'];
    if (date == null) return;
    final value = <String, Object?>{'date': date};
    await widget.repo.setField('task', widget.task.id, 'due', value);
    if (mounted) setState(() => _due = value);
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

  Future<void> _pickEnergy() async {
    final choice = await showChoiceSheet<String>(
      context,
      title: 'Energy',
      selected: _energy,
      items: const [
        ChoiceItem('', 'No energy'),
        ChoiceItem('deep', 'Deep work'),
        ChoiceItem('medium', 'Medium'),
        ChoiceItem('low', 'Low'),
      ],
    );
    if (choice == null || !mounted) return;
    await _setEnergy(choice);
  }

  Future<void> _setPriority(int value) async {
    setState(() => _priority = value);
    await widget.repo.setField('task', widget.task.id, 'priority', value);
  }

  Future<void> _pickPriority() async {
    final choice = await showChoiceSheet<int>(
      context,
      title: 'Priority',
      selected: _priority,
      items: const [
        ChoiceItem(1, 'Priority 1', icon: Icons.flag_rounded),
        ChoiceItem(2, 'Priority 2', icon: Icons.flag_rounded),
        ChoiceItem(3, 'Priority 3', icon: Icons.flag_rounded),
        ChoiceItem(4, 'Priority 4 (default)', icon: Icons.outlined_flag_rounded),
      ],
    );
    if (choice == null || !mounted) return;
    await _setPriority(choice);
  }

  Future<void> _moveToProject(String? value) async {
    if (value == _projectId) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _projectId = value);
    try {
      // Moving a parent carries every descendant; a subtask that leaves its
      // parent's project loses the parent.
      await widget.repo.moveToProject(widget.task, value);
      if (_sectionId != null) {
        await widget.repo.setField('task', widget.task.id, 'section_id', null);
        if (mounted) setState(() => _sectionId = null);
      }
      await _loadSections();
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _pickProject() async {
    // The Inbox is the empty id, so a dismissed sheet (null) is not mistaken for it.
    final choice = await showChoiceSheet<String>(
      context,
      title: 'Project',
      selected: _projectId ?? '',
      items: [
        const ChoiceItem('', 'Inbox', icon: Icons.inbox_outlined),
        for (final project in widget.projects)
          if (!project.isDeleted && !project.isArchived)
            ChoiceItem(project.id, project.name, icon: Icons.folder_outlined),
      ],
    );
    if (choice == null || !mounted) return;
    await _moveToProject(choice.isEmpty ? null : choice);
  }

  Future<void> _pickSection() async {
    final choice = await showChoiceSheet<String>(
      context,
      title: 'Section',
      selected: _sectionId ?? '',
      items: [
        const ChoiceItem('', 'No section'),
        for (final section in _sections) ChoiceItem(section.id, section.name),
      ],
    );
    if (choice == null || !mounted) return;
    await _setSection(choice.isEmpty ? null : choice);
  }

  Future<void> _clearStart() async {
    await widget.repo.setField('task', widget.task.id, 'start', null);
    if (mounted) setState(() => _start = null);
  }

  Future<void> _clearEstimate() async {
    await widget.repo.setField('task', widget.task.id, 'estimate_minutes', null);
    if (mounted) setState(() => _estimate = null);
  }

  Future<void> _toggleDone() async {
    // Ticking a repeating task finishes one occurrence: the series stays open and
    // comes round again, so the tick must not stick here.
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
  }

  Future<void> _delete() async {
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
    if (mounted) Navigator.of(context).pop(true);
  }

  String get _projectName {
    if (_projectId == null) return 'Inbox';
    for (final project in widget.projects) {
      if (project.id == _projectId) return project.name;
    }
    return 'Project';
  }

  /// What is set on the task, as chips: tap one to change it, tap its cross to
  /// clear it. The project is always shown, since it says where the task lives.
  List<Widget> _valueChips(String today, String? date, String? time, String? sectionName, ColorScheme scheme) {
    return [
      if (date != null)
        ValueChip(
          icon: Icons.event_rounded,
          label: friendlyDate(date, today),
          color: (daysBetween(today, date) ?? 0) < 0 ? scheme.error : detailColor(DetailKind.date),
          onTap: _pickDate,
          onClear: _clearDue,
        ),
      if (date != null && time != null)
        ValueChip(
          icon: Icons.schedule_rounded,
          label: time,
          color: detailColor(DetailKind.time),
          onTap: _pickTime,
          onClear: _clearTime,
        ),
      if (_deadline != null)
        ValueChip(
          icon: Icons.hourglass_top_rounded,
          label: 'Due by ${friendlyDate(_deadline!, today)}',
          color: detailColor(DetailKind.deadline),
          onTap: _pickDeadline,
          onClear: _clearDeadline,
        ),
      if (_start != null)
        ValueChip(
          icon: Icons.play_circle_outline,
          label: _start == 'someday' ? 'Someday' : 'From ${friendlyDate(_start!, today)}',
          color: detailColor(DetailKind.start),
          onTap: _pickStart,
          onClear: _clearStart,
        ),
      if (_estimate != null)
        ValueChip(
          icon: Icons.timelapse_rounded,
          label: durationLabel(_estimate!),
          color: detailColor(DetailKind.estimate),
          onTap: _pickEstimate,
          onClear: _clearEstimate,
        ),
      if (_energy.isNotEmpty)
        ValueChip(
          icon: Icons.bolt_rounded,
          label: switch (_energy) {
            'deep' => 'Deep work',
            'medium' => 'Medium',
            'low' => 'Low',
            _ => _energy,
          },
          color: detailColor(DetailKind.energy),
          onTap: _pickEnergy,
          onClear: () => _setEnergy(''),
        ),
      if (_recurrence.isNotEmpty)
        ValueChip(
          icon: Icons.repeat_rounded,
          label: _recurrenceLabel(_recurrence),
          color: detailColor(DetailKind.repeat),
          onTap: _seriesLoaded ? _pickRepeat : null,
          onClear: _seriesLoaded ? _clearRepeat : null,
        ),
      if (_priority < 4)
        ValueChip(
          icon: Icons.flag_rounded,
          label: 'Priority $_priority',
          color: priorityColor(_priority, scheme),
          onTap: _pickPriority,
          onClear: () => _setPriority(4),
        ),
      if (_labels.isNotEmpty)
        ValueChip(
          icon: Icons.label_outline_rounded,
          label: _labelNames(_labels),
          color: detailColor(DetailKind.labels),
          onTap: _editLabels,
          onClear: () => _setLabels(const []),
        ),
      if (sectionName != null)
        ValueChip(
          icon: Icons.view_stream_outlined,
          label: sectionName,
          onTap: _pickSection,
          onClear: () => _setSection(null),
        ),
      ValueChip(
        icon: _projectId == null ? Icons.inbox_outlined : Icons.folder_outlined,
        label: _projectName,
        muted: _projectId == null,
        dropdown: true,
        onTap: _pickProject,
      ),
    ];
  }

  /// The subtasks, right under the task's own details: each with its details in
  /// colour beneath its title, an edit button and a handle to drag it into place.
  Widget _subtaskSection(ThemeData theme, ColorScheme scheme, String today) {
    final labelNames = {for (final label in _allLabels) label.id: label.name};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 0, 0),
          child: Text(
            'SUBTASKS  $_subtaskDone/$_subtaskTotal',
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: _reorderChildren,
          children: [
            for (var i = 0; i < _children.length; i++)
              _subtaskRow(i, theme, scheme, today, labelNames),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: TextButton.icon(
              onPressed: _addSubtask,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add subtask'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _subtaskRow(int index, ThemeData theme, ColorScheme scheme, String today, Map<String, String> labelNames) {
    final child = _children[index];
    final chips = taskDetailChips(child, today: today, scheme: scheme, labelNames: labelNames);
    return Row(
      key: ValueKey(child.id),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        TaskCheck(
          done: child.isCompleted,
          priority: child.priority,
          onChanged: () => _toggleChild(child),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _editChild(child),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    child.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      decoration: child.isCompleted ? TextDecoration.lineThrough : null,
                      color: child.isCompleted ? scheme.onSurfaceVariant : scheme.onSurface,
                    ),
                  ),
                  if (chips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Wrap(spacing: 6, runSpacing: 4, children: chips),
                    ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Edit subtask',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.edit_outlined, size: 20, color: scheme.onSurfaceVariant),
          onPressed: () => _editChild(child),
        ),
        ReorderableDelayedDragStartListener(
          index: index,
          child: Semantics(
            button: true,
            label: 'Hold to reorder',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 10, 2, 10),
              child: Icon(Icons.drag_handle_rounded, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
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
    const gutter = EdgeInsets.only(left: 10);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(6, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaskCheck(done: _completed, priority: _priority, onChanged: _toggleDone),
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
              Padding(
                padding: gutter,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _valueChips(today, date, time, sectionName, scheme),
                ),
              ),
              if (_children.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Divider(),
                _subtaskSection(theme, scheme, today),
                const Divider(),
              ],
              const SizedBox(height: 10),
              Padding(
                padding: gutter,
                child: PropIconBar(
                  columns: 6,
                  children: [
                    PropIconButton(
                      icon: Icons.event_rounded,
                      tooltip: 'Date',
                      active: date != null,
                      onTap: _pickDate,
                    ),
                    PropIconButton(
                      icon: Icons.schedule_rounded,
                      tooltip: 'Time',
                      active: time != null,
                      onTap: _pickTime,
                    ),
                    PropIconButton(
                      icon: Icons.hourglass_top_rounded,
                      tooltip: 'Deadline',
                      active: _deadline != null,
                      onTap: _pickDeadline,
                    ),
                    PropIconButton(
                      icon: Icons.play_circle_outline,
                      tooltip: 'Start',
                      active: _start != null,
                      onTap: _pickStart,
                    ),
                    PropIconButton(
                      icon: Icons.timelapse_rounded,
                      tooltip: 'Estimate',
                      active: _estimate != null,
                      onTap: _pickEstimate,
                    ),
                    PropIconButton(
                      icon: Icons.bolt_rounded,
                      tooltip: 'Energy',
                      active: _energy.isNotEmpty,
                      onTap: _pickEnergy,
                    ),
                    PropIconButton(
                      icon: Icons.repeat_rounded,
                      tooltip: 'Repeat',
                      active: _recurrence.isNotEmpty,
                      onTap: _seriesLoaded ? _pickRepeat : null,
                    ),
                    PropIconButton(
                      icon: Icons.flag_rounded,
                      tooltip: 'Priority',
                      active: _priority < 4,
                      color: priorityColor(_priority, scheme),
                      onTap: _pickPriority,
                    ),
                    PropIconButton(
                      icon: Icons.folder_outlined,
                      tooltip: 'Project',
                      active: _projectId != null,
                      onTap: _pickProject,
                    ),
                    if (_projectId != null)
                      PropIconButton(
                        icon: Icons.view_stream_outlined,
                        tooltip: 'Section',
                        active: _sectionId != null,
                        onTap: _pickSection,
                      ),
                    PropIconButton(
                      icon: Icons.label_outline_rounded,
                      tooltip: 'Labels',
                      active: _labels.isNotEmpty,
                      onTap: _editLabels,
                    ),
                    PropIconButton(
                      icon: Icons.account_tree_outlined,
                      tooltip: 'Add subtask',
                      active: _subtaskTotal > 0,
                      onTap: _addSubtask,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: gutter,
                child: NotesField(
                  controller: _notes,
                  onSave: _saveNotes,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: gutter,
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
                  padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
                  child: Text(
                    'No files yet.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                for (final attachment in _attachments)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
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
              const SizedBox(height: 4),
              // Three actions and Done used to share a row of labelled buttons, and
              // on a narrow phone Done was pushed off the edge. The three are icons
              // now, so Done always fits.
              Padding(
                padding: gutter,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Delete',
                      color: scheme.error,
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                    IconButton(
                      tooltip: 'Share page',
                      color: scheme.onSurfaceVariant,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TaskPageScreen(repo: widget.repo, task: widget.task),
                        ),
                      ),
                      icon: const Icon(Icons.public_rounded),
                    ),
                    IconButton(
                      tooltip: 'History',
                      color: scheme.onSurfaceVariant,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TaskHistoryScreen(task: widget.task, repo: widget.repo),
                        ),
                      ),
                      icon: const Icon(Icons.history_rounded),
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
