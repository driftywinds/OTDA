import '../api/api_client.dart';

/// One field change inside an activity event or a history change set.
class ActivityChange {
  const ActivityChange({required this.field, required this.from, required this.to, this.lost = false});

  final String field;
  final Object? from;
  final Object? to;
  final bool lost;

  static ActivityChange fromJson(Map<String, dynamic> json) => ActivityChange(
        field: json['field']?.toString() ?? '',
        from: json['from'],
        to: json['to'],
        lost: json['lost'] == true,
      );
}

/// One event from `GET /api/v1/activity` or a task/project's activity route.
class ActivityEvent {
  const ActivityEvent({
    required this.id,
    required this.kind,
    required this.actor,
    required this.actorName,
    required this.entity,
    required this.entityId,
    required this.taskId,
    required this.taskTitle,
    required this.projectId,
    required this.projectName,
    required this.ts,
    required this.changes,
  });

  final String id;

  /// completed, created, commented, assigned, rescheduled, deleted, edited, …
  final String kind;
  final String actor;
  final String actorName;
  final String entity;
  final String entityId;
  final String? taskId;
  final String taskTitle;
  final String? projectId;
  final String projectName;
  final int ts;
  final List<ActivityChange> changes;

  static ActivityEvent fromJson(Map<String, dynamic> json) => ActivityEvent(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'edited',
        actor: json['actor']?.toString() ?? '',
        actorName: json['actorName']?.toString() ?? '',
        entity: json['entity']?.toString() ?? '',
        entityId: json['entityId']?.toString() ?? '',
        taskId: json['taskId']?.toString(),
        taskTitle: json['taskTitle']?.toString() ?? '',
        projectId: json['projectId']?.toString(),
        projectName: json['projectName']?.toString() ?? '',
        ts: (json['ts'] as num?)?.toInt() ?? 0,
        changes: [
          for (final raw in (json['changes'] as List?) ?? const [])
            if (raw is Map) ActivityChange.fromJson(raw.cast<String, dynamic>()),
        ],
      );
}

class ActivityPage {
  const ActivityPage(this.events, this.more, this.cursor);
  final List<ActivityEvent> events;
  final bool more;
  final String? cursor;
}

/// The cross-project feed and the per-task/per-project event lists.
///
/// The feed covers shared projects only: the server derives it from the shared
/// scopes a person is a member of, so personal tasks never appear there. A
/// personal task still has its own change history (see [taskHistory]).
class ActivityService {
  const ActivityService();

  Future<ActivityPage> feed(ApiClient client, {String? cursor, int limit = 30}) =>
      _events(client, '/api/v1/activity', cursor: cursor, limit: limit);

  Future<ActivityPage> forTask(ApiClient client, String taskId, {String? cursor, int limit = 50}) =>
      _events(client, '/api/v1/tasks/${Uri.encodeComponent(taskId)}/activity', cursor: cursor, limit: limit);

  Future<ActivityPage> _events(ApiClient client, String path,
      {String? cursor, required int limit}) async {
    final json = await client.get(path, query: {
      'limit': limit,
      if (cursor != null && cursor.isNotEmpty) 'before': cursor,
    }) as Map<String, dynamic>;
    return ActivityPage(
      [
        for (final raw in (json['events'] as List?) ?? const [])
          if (raw is Map) ActivityEvent.fromJson(raw.cast<String, dynamic>()),
      ],
      json['more'] == true,
      json['cursor']?.toString(),
    );
  }
}

/// One stored change set from `GET /api/v1/tasks/{id}/history`.
class HistoryChange {
  const HistoryChange({required this.field, required this.from, required this.to, this.lost = false});

  final String field;
  final Object? from;
  final Object? to;
  final bool lost;

  static HistoryChange fromJson(Map<String, dynamic> json) => HistoryChange(
        field: json['field']?.toString() ?? '',
        from: json['from'],
        to: json['to'],
        lost: json['lost'] == true,
      );
}

class HistoryChangeSet {
  const HistoryChangeSet({
    required this.ts,
    required this.device,
    required this.deviceLabel,
    required this.userId,
    required this.changes,
  });

  final int ts;
  final String device;
  final String deviceLabel;
  final String userId;
  final List<HistoryChange> changes;

  static HistoryChangeSet fromJson(Map<String, dynamic> json) => HistoryChangeSet(
        ts: (json['ts'] as num?)?.toInt() ?? 0,
        device: json['device']?.toString() ?? '',
        deviceLabel: json['device_label']?.toString() ?? '',
        userId: json['userId']?.toString() ?? '',
        changes: [
          for (final raw in (json['changes'] as List?) ?? const [])
            if (raw is Map) HistoryChange.fromJson(raw.cast<String, dynamic>()),
        ],
      );
}

class HistoryPage {
  const HistoryPage(this.changeSets, this.more, this.before);
  final List<HistoryChangeSet> changeSets;
  final bool more;
  final int? before;
}

/// The task history route: every field assignment, oldest first, paged with
/// `before` (a timestamp from the previous page).
class HistoryService {
  const HistoryService();

  Future<HistoryPage> task(ApiClient client, String taskId, {int? before, int limit = 50}) async {
    final json = await client.get(
      '/api/v1/tasks/${Uri.encodeComponent(taskId)}/history',
      query: {
        'limit': limit,
        'before': ?before,
      },
    ) as Map<String, dynamic>;
    return HistoryPage(
      [
        for (final raw in (json['changeSets'] as List?) ?? const [])
          if (raw is Map) HistoryChangeSet.fromJson(raw.cast<String, dynamic>()),
      ],
      json['more'] == true,
      (json['before'] as num?)?.toInt(),
    );
  }
}
