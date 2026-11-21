import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../data/activity_feed.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../e2ee/session.dart';

/// One task's change history, read from the server's op-log route and decrypted
/// on the device before it is shown.
class TaskHistoryScreen extends StatefulWidget {
  const TaskHistoryScreen({super.key, required this.task, required this.repo});

  final Task task;
  final Repo repo;

  @override
  State<TaskHistoryScreen> createState() => _TaskHistoryScreenState();
}

class _TaskHistoryScreenState extends State<TaskHistoryScreen> {
  static const _service = HistoryService();

  final _sets = <HistoryChangeSet>[];
  Map<String, String> _labels = const {};
  int? _before;
  bool _more = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = widget.repo.engine.client;
    final labels = await widget.repo.labels();
    if (!mounted) return;
    _labels = {for (final label in labels) label.id: label.name};
    try {
      final page = await _service.task(client, widget.task.id);
      if (!mounted) return;
      setState(() {
        _sets
          ..clear()
          ..addAll(page.changeSets.reversed);
        _before = page.before;
        _more = page.more;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.status == 404 ? 'This task has no history yet.' : e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingMore || !_more) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _service.task(widget.repo.engine.client, widget.task.id, before: _before);
      if (!mounted) return;
      setState(() {
        _sets.addAll(page.changeSets.reversed);
        _before = page.before;
        _more = page.more;
      });
    } on Object {
      // Keep what is on screen; the button can be pressed again.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _sets.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    if (_sets.isEmpty) const Text('No changes recorded yet.'),
                    for (final set in _sets) _ChangeSetCard(set: set, labels: _labels, taskId: widget.task.id),
                    if (_more)
                      Center(
                        child: TextButton(
                          onPressed: _loadingMore ? null : _loadOlder,
                          child: Text(_loadingMore ? 'Loading…' : 'Older changes'),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _ChangeSetCard extends StatelessWidget {
  const _ChangeSetCard({required this.set, required this.labels, required this.taskId});

  final HistoryChangeSet set;
  final Map<String, String> labels;
  final String taskId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final at = DateTime.fromMillisecondsSinceEpoch(set.ts).toLocal();
    final device = set.deviceLabel.isNotEmpty
        ? set.deviceLabel
        : set.device == 'server'
            ? 'Server'
            : set.device.startsWith('otda:')
                ? 'This device'
                : set.device;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_day(at)} · ${_time(at)} · $device',
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            for (final change in set.changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${_field(change.field)}: ',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: '${_value(change)}${change.lost ? '  (kept a newer value)' : ''}'),
                    ],
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _field(String field) => switch (field) {
        'title' => 'Title',
        'description' => 'Notes',
        'due' => 'Due',
        'deadline' => 'Deadline',
        'start' => 'Start',
        'priority' => 'Priority',
        'labels' => 'Labels',
        'project_id' => 'Project',
        'section_id' => 'Section',
        'estimate_minutes' => 'Estimate',
        'energy' => 'Energy',
        'completed_at' => 'Completed',
        'deleted_at' => 'Trash',
        'recurrence' => 'Repeat',
        'parent_id' => 'Parent',
        _ => field,
      };

  String _value(HistoryChange change) {
    final from = _plain(change.field, change.from);
    final to = _plain(change.field, change.to);
    if (to.isEmpty) return 'cleared';
    return from.isEmpty ? to : '$from → $to';
  }

  String _plain(String field, Object? raw) {
    final opened = E2eeSession.instance.open('task', taskId, field, raw);
    if (opened == null) return '';
    if (opened is Map) {
      final date = opened['date']?.toString() ?? '';
      final time = opened['time']?.toString();
      return time == null ? date : '$date $time';
    }
    if (opened is List) {
      if (field == 'labels') {
        return opened.map((id) => labels[id] ?? id.toString()).join(', ');
      }
      return opened.join(', ');
    }
    if (opened is bool) return opened ? 'yes' : 'no';
    if (field == 'completed_at' || field == 'deleted_at') {
      if (opened is num) {
        final date = DateTime.fromMillisecondsSinceEpoch(opened.toInt()).toLocal();
        return '${_day(date)} ${_time(date)}';
      }
    }
    return opened.toString();
  }

  static String _day(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static String _time(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
