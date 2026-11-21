import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../api/api_exception.dart';
import '../data/activity_feed.dart';
import '../e2ee/session.dart';

/// The account's activity across shared projects, newest first.
///
/// The server derives it from the operation log and only covers shared
/// projects; a personal task keeps its own history in the task sheet.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  static const _service = ActivityService();

  final _scroll = ScrollController();
  final _events = <ActivityEvent>[];
  String? _cursor;
  bool _more = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_more) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _load() async {
    final client = widget.state.client;
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _service.feed(client);
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll(page.events);
        _cursor = page.cursor;
        _more = page.more;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _explain(e));
    } on Object {
      if (mounted) setState(() => _error = 'The activity feed could not be read.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final client = widget.state.client;
    if (client == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _service.feed(client, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _events.addAll(page.events);
        _cursor = page.cursor;
        _more = page.more;
      });
    } on Object {
      // The first page is still on screen; the next scroll tries again.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _explain(ApiException e) => switch (e.code) {
        'network' || 'timeout' => 'Connect to the server to read activity.',
        'unauthorized' => 'Sign in again to read activity.',
        _ => e.message.isEmpty ? 'The activity feed could not be read.' : e.message,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('Try again')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _events.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 80),
                            Icon(Icons.timeline_rounded, size: 44, color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                            Text('No activity yet', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                'The feed covers shared projects. Personal tasks keep their history in the task sheet.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                          itemCount: _events.length + (_more ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _events.length) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                              );
                            }
                            return _EventRow(event: _events[index], me: widget.state.account?.userId ?? '');
                          },
                        ),
                ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.me});

  final ActivityEvent event;
  final String me;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, label) = _kind(event.kind);
    final title = _text('title', event.taskTitle);
    final actor = event.actor == me ? 'You' : (event.actorName.isEmpty ? 'Someone' : event.actorName);
    final changes = [
      for (final change in event.changes.take(2))
        _changeText(change),
    ].where((text) => text.isNotEmpty).join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 12, 6),
        leading: Icon(icon, color: scheme.primary),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title.isEmpty ? label : '$label · $title',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              [actor, if (event.projectName.isNotEmpty) event.projectName, _ago(event.ts)].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (changes.isNotEmpty)
              Text(
                changes,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  String _text(String field, String raw) {
    if (raw.isEmpty) return '';
    final value = E2eeSession.instance.open('task', event.taskId ?? event.entityId, field, raw);
    return value?.toString() ?? '';
  }

  String _changeText(ActivityChange change) {
    final from = _value(change.field, change.from);
    final to = _value(change.field, change.to);
    if (from.isEmpty && to.isEmpty) return '';
    return '${_field(change.field)}: ${from.isEmpty ? 'empty' : from} → ${to.isEmpty ? 'empty' : to}';
  }

  String _value(String field, Object? raw) {
    final value = E2eeSession.instance.open('task', event.taskId ?? event.entityId, field, raw);
    if (value == null) return '';
    if (value is Map) {
      final date = value['date']?.toString() ?? '';
      final time = value['time']?.toString();
      return time == null ? date : '$date $time';
    }
    if (value is List) return value.join(', ');
    if (value is bool) return value ? 'yes' : 'no';
    return value.toString();
  }

  String _field(String field) => switch (field) {
        'completed_at' => 'Completed',
        'deleted_at' => 'Deleted',
        'due' => 'Due',
        'priority' => 'Priority',
        'project_id' => 'Project',
        'title' => 'Title',
        'description' => 'Notes',
        _ => field,
      };

  (IconData, String) _kind(String kind) => switch (kind) {
        'completed' => (Icons.check_circle_outline, 'Completed'),
        'created' => (Icons.add_task_rounded, 'Created'),
        'commented' => (Icons.chat_bubble_outline_rounded, 'Commented'),
        'assigned' => (Icons.person_outline_rounded, 'Assigned'),
        'rescheduled' => (Icons.event_repeat_rounded, 'Rescheduled'),
        'deleted' => (Icons.delete_outline_rounded, 'Deleted'),
        'archived' => (Icons.archive_outlined, 'Archived'),
        _ => (Icons.edit_outlined, 'Edited'),
      };

  String _ago(int millis) {
    if (millis <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
  }
}
