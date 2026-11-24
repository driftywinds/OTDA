import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../api/api_exception.dart';
import 'clock.dart';
import '../util/log.dart';
import 'db.dart';
import 'models.dart';
import '../quickadd/rule.dart' as rules;
import 'series.dart';
import 'sync_engine.dart';

/// Reads the replica and writes through it: every change is a field write plus
/// a queued op, so it works offline and syncs later.
class Repo {
  Repo({required this.db, required this.clock, required this.engine});

  final OtdaDb db;
  final HybridClock clock;
  final SyncEngine engine;

  Future<List<Task>> tasks() async {
    final rows = await db.entities('task');
    // A project in the Trash hides its tasks: they keep their project_id, and
    // restoring the project (one field) brings them back. Filtering here keeps
    // Today, reminders and the widget honest without touching the rows.
    final projects = await db.entities('project', includeDeleted: true);
    final trashed = {
      for (final project in projects)
        if (project['deleted_at'] != null) project['id'] as String,
    };
    return [
      for (final row in rows)
        if (row['project_id'] == null || !trashed.contains(row['project_id']))
          Task(row['id'] as String, row),
    ];
  }

  Future<List<Project>> projects() async =>
      (await db.entities('project')).map((e) => Project(e['id'] as String, e)).toList();

  /// Every project, tombstones included, for the Trash view.
  Future<List<Project>> allProjects() async => (await db.entities('project', includeDeleted: true))
      .map((e) => Project(e['id'] as String, e))
      .toList();

  /// Deleted tasks, newest deletion first.
  Future<List<Task>> trashedTasks() async {
    final rows = await db.entities('task', includeDeleted: true);
    final tasks = [
      for (final row in rows)
        if (row['deleted_at'] != null) Task(row['id'] as String, row),
    ];
    tasks.sort((a, b) => _deletedAt(b.raw).compareTo(_deletedAt(a.raw)));
    return tasks;
  }

  /// Deleted projects, newest deletion first.
  Future<List<Project>> trashedProjects() async {
    final projects = [
      for (final project in await allProjects())
        if (project.isDeleted) project,
    ];
    projects.sort((a, b) => _deletedAt(b.raw).compareTo(_deletedAt(a.raw)));
    return projects;
  }

  static int _deletedAt(Map<String, Object?> raw) {
    final value = raw['deleted_at'];
    return value is num ? value.toInt() : 0;
  }

  Future<List<Label>> labels() async =>
      (await db.entities('label')).map((e) => Label(e['id'] as String, e)).toList();

  /// The live sections of a project, in board order.
  Future<List<Section>> sections(String projectId) async {
    final rows = await db.entities('section');
    return [
      for (final row in rows)
        if (row['project_id']?.toString() == projectId) Section(row['id'] as String, row),
    ]..sort((a, b) => a.position.compareTo(b.position));
  }

  /// The live attachments of a task, oldest first.
  Future<List<Attachment>> attachments(String taskId) async {
    final rows = await db.entities('attachment');
    final out = [
      for (final row in rows)
        if (row['task_id']?.toString() == taskId && row['deleted_at'] == null)
          Attachment(row),
    ];
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  /// Every live attachment, for the lifecycle's file guard.
  Future<List<Attachment>> allAttachments() async {
    final rows = await db.entities('attachment');
    return [
      for (final row in rows)
        if (row['deleted_at'] == null) Attachment(row),
    ];
  }

  /// Creates an entity from a field map, one op per field. Used for an
  /// attachment row, whose fields are all known at creation.
  Future<void> createEntity(String entity, String id, Map<String, Object?> fields) async {
    for (final entry in fields.entries) {
      final ts = await clock.next();
      await db.putField(entity, id, entry.key, entry.value, ts, engine.device);
    }
  }

  /// The workspaces the sync exchange last reported, in the server's order.
  Future<List<Workspace>> workspaces() async {
    final raw = await db.meta('sync.workspaces');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map) Workspace(entry.cast<String, dynamic>()),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// The shared projects the sync exchange last reported, with roles and
  /// members. A personal project has no entry.
  Future<List<ProjectMembership>> memberships() async {
    final raw = await db.meta('sync.memberships');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map) ProjectMembership(entry.cast<String, dynamic>()),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<ProjectMembership?> membershipFor(String projectId) async {
    for (final membership in await memberships()) {
      if (membership.projectId == projectId) return membership;
    }
    return null;
  }

  /// The account's own preferences: one synced row per account under `me`
  /// (`date_format`, `week_start`, `language`, `row_layout`, …). Absent fields
  /// mean "follow the device", as the server's defaults do.
  Future<Map<String, Object?>> userPrefs() async =>
      await db.entity('user_prefs', 'me') ?? <String, Object?>{'id': 'me'};

  Future<void> setUserPref(String field, Object? value) =>
      setField('user_prefs', 'me', field, value);

  /// The id of the label with this name (case-insensitive), creating it when it
  /// does not exist yet — what the web app does when a quick-add line names a
  /// label that is not there.
  Future<String> ensureLabel(String name) async {
    final wanted = name.trim();
    final existing = await labels();
    for (final label in existing) {
      if (label.name.toLowerCase() == wanted.toLowerCase()) return label.id;
    }
    final id = newId();
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in {
      'name': wanted,
      'created_at': now,
      'position': now.toDouble(),
    }.entries) {
      await db.putField('label', id, entry.key, entry.value, ts, engine.device);
    }
    return id;
  }

  /// Turns the names a quick-add line produced into label ids.
  Future<List<String>> resolveLabelNames(Iterable<Object?> names) async {
    final ids = <String>[];
    for (final raw in names) {
      final name = raw is Map ? (raw['name']?.toString() ?? '') : (raw?.toString() ?? '');
      if (name.trim().isEmpty) continue;
      ids.add(await ensureLabel(name));
    }
    return ids;
  }

  Future<Task?> task(String id) async {
    final row = await db.entity('task', id);
    return row == null ? null : Task(id, row);
  }

  /// New task with the same defaults the server applies, so it looks right
  /// before the first exchange.
  Future<Task> createTask(String title, {String? projectId, Map<String, Object?> extra = const {}}) async {
    final id = newId();
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fields = <String, Object?>{
      'title': title.trim(),
      'created_at': now,
      'position': now.toDouble(),
      'priority': 4,
      'labels': const <String>[],
      'blocked_by': const <String>[],
      'project_id': projectId,
      ...extra,
    };
    for (final entry in fields.entries) {
      await db.putField('task', id, entry.key, entry.value, ts, engine.device);
    }
    return Task(id, {'id': id, ...fields});
  }

  Future<void> setField(String entity, String entityId, String field, Object? value) async {
    final ts = await clock.next();
    await db.putField(entity, entityId, field, value, ts, engine.device);
  }

  /// Queues a wire value while the replica shows [localValue]. The encryption
  /// migration uses it so lists keep plaintext even though the server receives
  /// ciphertext.
  Future<void> queueField(
    String entity,
    String entityId,
    String field,
    Object? wireValue, {
    Object? localValue,
    bool updateLocal = false,
  }) async {
    final ts = await clock.next();
    await db.enqueueField(entity, entityId, field, wireValue, ts, engine.device);
    if (updateLocal) await db.setLocalValue(entity, entityId, field, localValue);
  }

  /// The live direct children of a task, in manual order.
  Future<List<Task>> childrenOf(String parentId) async {
    final rows = await db.entities('task');
    final children = [
      for (final row in rows)
        if (row['parent_id']?.toString() == parentId) Task(row['id'] as String, row),
    ];
    children.sort((a, b) {
      final byPosition = _position(a).compareTo(_position(b));
      if (byPosition != 0) return byPosition;
      return (a.createdAt ?? 0).compareTo(b.createdAt ?? 0);
    });
    return children;
  }

  static double _position(Task task) => (task.raw['position'] as num?)?.toDouble() ?? 0;

  /// A new subtask: the parent's project, priority 4 and no due date, placed
  /// after its last sibling. It exists locally at once, like any other write.
  Future<Task> createSubtask(Task parent, String title) async {
    final siblings = await childrenOf(parent.id);
    final position = siblings.isEmpty ? 0.0 : _position(siblings.last) + 1;
    return createTask(
      title,
      projectId: parent.projectId,
      extra: {'parent_id': parent.id, 'priority': 4, 'position': position},
    );
  }

  /// Direct children progress: completed / total, deleted children count
  /// nowhere. Derived, never stored.
  Future<({int done, int total})> subtaskProgress(String taskId) async {
    final children = await childrenOf(taskId);
    return (done: children.where((c) => c.isCompleted).length, total: children.length);
  }

  /// The position a new child of [parentId] takes: after the last sibling.
  Future<double> nextChildPosition(String parentId) async {
    final siblings = await childrenOf(parentId);
    return siblings.isEmpty ? 0 : _position(siblings.last) + 1;
  }

  /// Moves a task under another parent, or to the top level. The server's rule
  /// is the same as the web client's: same project, no cycle, no self.
  Future<void> setParent(Task task, String? parentId) async {
    final rows = await db.entities('task');
    final byId = {for (final row in rows) row['id'] as String: Task(row['id'] as String, row)};
    if (parentId != null) {
      if (parentId == task.id) throw const ApiException(400, 'invalid_parent', 'a task cannot be its own parent');
      final parent = byId[parentId];
      if (parent == null || parent.isDeleted) {
        throw const ApiException(404, 'parent_not_found', 'that parent no longer exists');
      }
      if (parent.projectId != task.projectId) {
        throw const ApiException(400, 'parent_other_project', 'a subtask must stay in its parent\'s project');
      }
      // A task may not move under its own descendant.
      var cursor = parent.parentId;
      for (var depth = 0; cursor != null && depth < 64; depth++) {
        if (cursor == task.id) {
          throw const ApiException(400, 'parent_cycle', 'that would put the task under itself');
        }
        cursor = byId[cursor]?.parentId;
      }
    }
    final siblings = parentId == null
        ? [
            for (final candidate in byId.values)
              if (candidate.parentId == null && candidate.id != task.id) candidate,
          ]
        : [
            for (final candidate in byId.values)
              if (candidate.parentId == parentId && candidate.id != task.id) candidate,
          ];
    siblings.sort((a, b) => _position(a).compareTo(_position(b)));
    final position = siblings.isEmpty ? 0.0 : _position(siblings.last) + 1;
    final ts = await clock.next();
    await db.putField('task', task.id, 'parent_id', parentId, ts, engine.device);
    await db.putField('task', task.id, 'position', position, ts, engine.device);
  }

  /// Moves a task and every live descendant to another project, one op per
  /// task. A section belongs to its project, so it is cleared with the move.
  Future<void> moveToProject(Task task, String? projectId) async {
    final rows = await db.entities('task');
    final children = <String, List<String>>{};
    for (final row in rows) {
      final parent = row['parent_id']?.toString();
      if (parent != null && parent.isNotEmpty) {
        children.putIfAbsent(parent, () => []).add(row['id'] as String);
      }
    }
    final ids = <String>{task.id};
    final queue = [task.id];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <String>[]) {
        if (ids.add(child)) queue.add(child);
      }
    }
    final ts = await clock.next();
    for (final id in ids) {
      await db.putField('task', id, 'project_id', projectId, ts, engine.device);
      final row = await db.entity('task', id);
      if (row?['section_id'] != null) {
        await db.putField('task', id, 'section_id', null, ts, engine.device);
      }
    }
    // A parent stays in its own project; a task moved elsewhere leaves it.
    final parentId = task.parentId;
    if (parentId != null) {
      final parent = await db.entity('task', parentId);
      if (parent?['project_id']?.toString() != projectId?.toString()) {
        await db.putField('task', task.id, 'parent_id', null, ts, engine.device);
      }
    }
  }

  /// Marks one occurrence done.
  ///
  /// A plain task gets `completed_at` and is finished. A repeating one is a
  /// series: the occurrence in front of you becomes its own record (what the web
  /// client writes) and the series moves to its next date, so a daily task comes
  /// back tomorrow instead of disappearing. Only when the series has run out does
  /// the series itself complete, which is what the web does too.
  Future<void> setCompleted(Task task, bool completed, {bool skipped = false}) async {
    final raw = task.raw['recurrence']?.toString() ?? '';
    final recurring = raw.isNotEmpty && rules.parseRule(raw).ok;
    final now = DateTime.now().millisecondsSinceEpoch;

    // An occurrence record is not a task of its own: un-ticking it has to put the
    // series back on that day, or the record becomes an open one-off and Upcoming
    // shows both it and the series' next occurrence.
    final seriesId = task.raw['series_id']?.toString();
    if (seriesId != null && seriesId.isNotEmpty) {
      final ts = await clock.next();
      if (completed) {
        // A re-tick after an undo must clear the tombstone: the record id is
        // derived from series and date, so the row is the same one that was undone,
        // and leaving deleted_at set made the task invisible for ever while the
        // series rolled on without it.
        await db.putField('task', task.id, 'completed_at', now, ts, engine.device);
        await db.putField('task', task.id, 'deleted_at', null, ts, engine.device);
        await db.putField('task', task.id, 'skipped', false, ts, engine.device);
        return;
      }
      final recordDate = task.raw['occurrence_date']?.toString() ?? occurrenceDateOf(task, _todayString());
      final rows = await db.entities('task');
      final seriesRow = rows.where((row) => row['id']?.toString() == seriesId).firstOrNull;
      await db.putField('task', task.id, 'deleted_at', now, ts, engine.device);
      if (seriesRow != null) {
        final series = Task(seriesId, seriesRow);
        await db.putField('task', seriesId, 'completed_at', null, ts, engine.device);
        await db.putField('task', seriesId, 'due', movedDue(series, recordDate), ts, engine.device);
      }
      return;
    }

    if (!recurring) {
      final ts = await clock.next();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!completed) {
        // Reopening a parent reopens only the parent; never its subtasks.
        await db.putField('task', task.id, 'completed_at', null, ts, engine.device);
        return;
      }
      // Completing a plain task completes its open descendants too: one
      // completion op per task, so the result converges on every device.
      final rows = await db.entities('task');
      final children = <String, List<String>>{};
      for (final row in rows) {
        final parent = row['parent_id']?.toString();
        if (parent != null && parent.isNotEmpty) {
          children.putIfAbsent(parent, () => []).add(row['id'] as String);
        }
      }
      final ids = <String>{task.id};
      final queue = [task.id];
      while (queue.isNotEmpty) {
        for (final child in children[queue.removeLast()] ?? const <String>[]) {
          if (ids.add(child)) queue.add(child);
        }
      }
      for (final id in ids) {
        final row = await db.entity('task', id);
        if (row == null || row['completed_at'] != null) continue;
        await db.putField('task', id, 'completed_at', now, ts, engine.device);
      }
      return;
    }

    final today = _todayString();
    final all = await db.entities('task');
    final tasks = [for (final row in all) Task(row['id'] as String, row)];
    final date = currentOccurrence(task, tasks, today) ?? occurrenceDateOf(task, today);

    if (!completed) {
      // Undoing the last tick: the series has already moved on, so the occurrence
      // to go back to is the one its newest live record stands for.
      final rows = await db.entities('task');
      Map<String, Object?>? record;
      for (final row in rows) {
        if (row['series_id']?.toString() == task.id &&
            row['deleted_at'] == null &&
            row['completed_at'] != null &&
            (record == null ||
                (row['occurrence_date']?.toString() ?? '').compareTo(
                      record['occurrence_date']?.toString() ?? '',
                    ) >
                    0)) {
          record = row;
        }
      }
      final back = record?['occurrence_date']?.toString() ?? date;
      final ts = await clock.next();
      if (record != null) {
        await db.putField('task', record['id'] as String, 'deleted_at', now, ts, engine.device);
      }
      await db.putField('task', task.id, 'completed_at', null, ts, engine.device);
      await db.putField('task', task.id, 'due', movedDue(task, back), ts, engine.device);
      return;
    }

    // A row that the series has already moved past: the list still held it when the
    // tap happened (a second tap, a widget tap racing the refresh). Completing it
    // would write the *next* occurrence and skip a day, which is exactly how a daily
    // task lost today and tomorrow.
    final tapped = task.dueDate;
    if (tapped != null && tapped != date) {
      otdaLog('complete: ${task.id} row=$tapped but the series is on $date, ignoring the stale tap');
      return;
    }

    // Already done for this occurrence: nothing to roll.
    final existing = tasks.where(
      (t) => t.raw['series_id']?.toString() == task.id && t.raw['occurrence_date']?.toString() == date,
    );
    for (final record in existing) {
      if (!record.isDeleted && record.isCompleted) {
        otdaLog('complete: ${task.id} $date already done, not rolling again');
        return;
      }
    }

    final budget = seriesBudget(task, tasks, exceptDate: date);
    final next = nextFree(
      raw,
      task.dueDate,
      today,
      today,
      budget.taken,
      budget.except,
    );
    if (next == null) {
      // The end condition is reached: the series completes like a plain task.
      final ts = await clock.next();
      await db.putField('task', task.id, 'completed_at', now, ts, engine.device);
      return;
    }

    final ts = await clock.next();
    final recordId = occurrenceIdOf(task.id, date);
    final fields = occurrenceFields(task, date, now, today);
    otdaLog('complete: series ${task.id} date=$date record=$recordId next=$next '
        'due=${fields['due']} completed_at=${fields['completed_at']}');
    if (skipped) fields['skipped'] = true;
    for (final entry in fields.entries) {
      await db.putField('task', recordId, entry.key, entry.value, ts, engine.device);
    }
    // The record id is derived from series and date, so an earlier undo left this
    // same row tombstoned; ticking again must clear that, not write around it.
    await db.putField('task', recordId, 'deleted_at', null, ts, engine.device);
    for (final entry in movedDates(task, next, today).entries) {
      await db.putField('task', task.id, entry.key, entry.value, ts, engine.device);
    }
  }

  /// Deletes a series in one of the three scopes the model supports.
  ///
  /// One occurrence is a skip: the record says so and the series moves on, exactly
  /// as the web client's delete does for an open occurrence of a live series.
  /// Everything from here on is a truncation: the rule ends the day before, and
  /// the series itself completes because nothing of it remains. Deleting every
  /// occurrence tombstones the series and the records it wrote.
  Future<void> deleteSeries(Task task, SeriesScope scope) async {
    switch (scope) {
      case SeriesScope.occurrence:
        await setCompleted(task, true, skipped: true);
      case SeriesScope.future:
        final ts = await clock.next();
        final today = _todayString();
        final all = await db.entities('task');
        final tasks = [for (final row in all) Task(row['id'] as String, row)];
        final date = currentOccurrence(task, tasks, today) ?? occurrenceDateOf(task, today);
        final raw = task.raw['recurrence']?.toString() ?? '';
        await db.putField('task', task.id, 'recurrence', rules.ruleWithUntil(raw, addDays(date, -1)), ts,
            engine.device);
        if (task.isCompleted == false) {
          await db.putField('task', task.id, 'completed_at', DateTime.now().millisecondsSinceEpoch, ts,
              engine.device);
        }
      case SeriesScope.all:
        final ts = await clock.next();
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.putField('task', task.id, 'deleted_at', now, ts, engine.device);
        for (final row in await db.entities('task')) {
          if (row['series_id']?.toString() == task.id && row['deleted_at'] == null) {
            await db.putField('task', row['id'] as String, 'deleted_at', now, ts, engine.device);
          }
        }
    }
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> trash(Task task) async {
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    // Deleting a task tombstones its whole subtree, one op per task, with the
    // same clock. That is what lets a restore bring back exactly what was
    // deleted together (the web client's deleteTask does the same).
    final rows = await db.entities('task', includeDeleted: true);
    final children = <String, List<String>>{};
    for (final row in rows) {
      final parent = row['parent_id']?.toString();
      if (parent != null && parent.isNotEmpty) {
        children.putIfAbsent(parent, () => []).add(row['id'] as String);
      }
    }
    final ids = <String>{task.id};
    final queue = [task.id];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <String>[]) {
        if (ids.add(child)) queue.add(child);
      }
    }
    for (final id in ids) {
      await db.putField('task', id, 'deleted_at', now, ts, engine.device);
    }
  }

  /// Puts a trashed task back, with the descendants that were deleted with it
  /// (same `deleted_at`), in one batch. A task whose project is still in the
  /// Trash goes to the Inbox, because a live task must not point at a dead
  /// project; a task whose parent is still deleted comes back at the top level.
  Future<void> restoreTask(Task task) async {
    // Read the row again: the Task the caller holds may predate the delete.
    final row = await db.entity('task', task.id);
    final deletedAt = row?['deleted_at'];
    if (deletedAt == null) return;
    final stamp = deletedAt.toString();
    final rows = await db.entities('task', includeDeleted: true);
    final byId = {for (final row in rows) row['id'] as String: row};
    final self = byId[task.id] ?? row!;
    final children = <String, List<String>>{};
    for (final row in rows) {
      final parent = row['parent_id']?.toString();
      if (parent != null && parent.isNotEmpty) {
        children.putIfAbsent(parent, () => []).add(row['id'] as String);
      }
    }
    final subtree = <String>{task.id};
    final queue = [task.id];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <String>[]) {
        final row = byId[child];
        if (row != null && row['deleted_at']?.toString() == stamp && subtree.add(child)) {
          queue.add(child);
        }
      }
    }

    final projectId = self['project_id']?.toString();
    final project = projectId == null ? null : await db.entity('project', projectId);
    final projectGone = project != null && project['deleted_at'] != null;
    final parentId = self['parent_id']?.toString();
    final parent = parentId == null ? null : byId[parentId];
    final parentGone = parentId != null &&
        !subtree.contains(parentId) &&
        (parent == null || parent['deleted_at'] != null);

    final ts = await clock.next();
    for (final id in subtree) {
      await db.putField('task', id, 'deleted_at', null, ts, engine.device);
      if (projectGone) {
        await db.putField('task', id, 'project_id', null, ts, engine.device);
        // A section belongs to the project that is still in the Trash.
        if (byId[id]?['section_id'] != null) {
          await db.putField('task', id, 'section_id', null, ts, engine.device);
        }
      }
    }
    if (parentGone) {
      await db.putField('task', task.id, 'parent_id', null, ts, engine.device);
    }
  }

  /// Clearing a project's tombstone is the whole restore: its tasks kept their
  /// `project_id`, so they reappear on their own.
  Future<void> restoreProject(Project project) async {
    if (!project.isDeleted) return;
    await setField('project', project.id, 'deleted_at', null);
  }

  /// Permanently deletes one trashed task and the deleted descendants the
  /// server removes with it. The server is the one that can purge; offline this
  /// throws and the row stays in the Trash.
  Future<void> purgeTask(Task task) async {
    await engine.client.delete('/api/v1/tasks/${Uri.encodeComponent(task.id)}/purge',
        timeout: const Duration(seconds: 90));
    final rows = await db.entities('task', includeDeleted: true);
    final children = <String, List<String>>{};
    for (final row in rows) {
      final parent = row['parent_id']?.toString();
      if (parent != null && parent.isNotEmpty) {
        children.putIfAbsent(parent, () => []).add(row['id'] as String);
      }
    }
    final ids = <String>{task.id};
    final queue = [task.id];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <String>[]) {
        final row = rows.where((r) => r['id'] == child).firstOrNull;
        if (row != null && row['deleted_at'] != null && ids.add(child)) queue.add(child);
      }
    }
    for (final id in ids) {
      await db.purgeEntity('task', id);
    }
  }

  /// Purging a project removes the project and every task referencing it, as
  /// the server does.
  Future<void> purgeProject(Project project) async {
    await engine.client.delete('/api/v1/projects/${Uri.encodeComponent(project.id)}/purge',
        timeout: const Duration(seconds: 90));
    await _purgeProjectLocally(project.id);
  }

  /// Empties the whole Trash on the server, then removes the same rows here so
  /// the view does not wait for the next exchange.
  Future<void> emptyTrash() async {
    await engine.client.post('/api/v1/trash/purge', timeout: const Duration(minutes: 2));
    for (final project in await trashedProjects()) {
      await _purgeProjectLocally(project.id);
    }
    const entities = {
      'task',
      'project',
      'section',
      'field',
      'note',
      'comment',
      'attachment',
      'time_entry',
      'view',
      'label',
      'reminder',
      'rule',
    };
    for (final entity in entities) {
      for (final row in await db.entities(entity, includeDeleted: true)) {
        if (row['deleted_at'] != null) await db.purgeEntity(entity, row['id'] as String);
      }
    }
  }

  Future<void> _purgeProjectLocally(String id) async {
    await db.purgeEntity('project', id);
    for (final entity in const ['task', 'section', 'field', 'note']) {
      for (final row in await db.entities(entity, includeDeleted: true)) {
        if (row['project_id']?.toString() == id) {
          await db.purgeEntity(entity, row['id'] as String);
        }
      }
    }
  }

  /// How many items wait in the Trash, for the Settings row.
  Future<int> trashCount() async =>
      (await trashedTasks()).length + (await trashedProjects()).length;

  /// Snoozes one occurrence on this device. Never synced: a snooze is a local
  /// decision, and the plan reads it back through [snoozes]. The keys live in one
  /// index row so they can be listed without scanning every task.
  Future<void> setSnooze(String taskId, String day, DateTime? until) async {
    final key = '$taskId|$day';
    await db.setMeta('snooze:$key', until == null ? '' : '${until.millisecondsSinceEpoch}');
    final index = await _snoozeIndex();
    if (until == null) {
      index.remove(key);
    } else {
      index.add(key);
    }
    await db.setMeta('snooze_index', index.join('\n'));
  }

  Future<Set<String>> _snoozeIndex() async =>
      ((await db.meta('snooze_index')) ?? '').split('\n').where((k) => k.isNotEmpty).toSet();

  /// The snoozes still in the future, keyed `taskId|day`.
  Future<Map<String, DateTime>> snoozes() async {
    final out = <String, DateTime>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    final index = await _snoozeIndex();
    for (final key in index) {
      final at = int.tryParse(await db.meta('snooze:$key') ?? '');
      if (at != null && at > now) out[key] = DateTime.fromMillisecondsSinceEpoch(at);
    }
    // Forget the ones that have passed so the index does not grow for ever.
    if (out.length != index.length) await db.setMeta('snooze_index', out.keys.join('\n'));
    return out;
  }

  /// Relative reminders in minutes before the due time, keyed by task. OpenTodo
  /// stores these as separate `reminder` entities; the repeat sheet manages one
  /// per task, so the first live relative reminder wins.
  Future<Map<String, int>> reminderOffsets() async {
    final out = <String, int>{};
    for (final row in await db.entities('reminder')) {
      if (row['deleted_at'] != null || row['kind'] != 'relative') continue;
      final taskId = row['task_id']?.toString();
      final offset = row['offset_minutes'];
      if (taskId == null || taskId.isEmpty || offset is! num) continue;
      out.putIfAbsent(taskId, () => (-offset).round());
    }
    return out;
  }

  Future<int?> taskReminderOffset(String taskId) async => (await reminderOffsets())[taskId];

  /// Creates, updates or clears the reminder the repeat sheet owns for [task].
  /// [minutes] is minutes before the due time; the wire value is negative.
  Future<void> setTaskReminderOffset(Task task, int? minutes) async {
    final rows = (await db.entities('reminder'))
        .where((row) =>
            row['deleted_at'] == null &&
            row['task_id'] == task.id &&
            row['kind'] == 'relative')
        .toList();
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (minutes == null) {
      if (rows.isEmpty) return;
      await db.putField('reminder', rows.first['id'] as String, 'deleted_at', now, ts, engine.device);
      return;
    }
    if (rows.isNotEmpty) {
      await db.putField('reminder', rows.first['id'] as String, 'offset_minutes', -minutes, ts, engine.device);
      return;
    }
    await createEntity('reminder', newId(), {
      'task_id': task.id,
      'kind': 'relative',
      'offset_minutes': -minutes,
      'created_at': now,
    });
  }

  /// Renames a project or changes its colour or icon, one field at a time.
  Future<void> updateProject(String projectId, Map<String, Object?> fields) async {
    final ts = await clock.next();
    for (final entry in fields.entries) {
      await db.putField('project', projectId, entry.key, entry.value, ts, engine.device);
    }
  }

  /// A project delete is a tombstone, like a task's: the row stays so every
  /// other device learns it is gone.
  Future<void> trashProject(String projectId) async {
    final ts = await clock.next();
    await db.putField(
        'project', projectId, 'deleted_at', DateTime.now().millisecondsSinceEpoch, ts, engine.device);
  }

  Future<Project> createProject(String name, {String? color, String? icon, String? workspaceId}) async {
    final id = newId();
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fields = <String, Object?>{
      'name': name.trim(),
      'created_at': now,
      'position': now.toDouble(),
      if (color != null && color.isNotEmpty) 'color': color,
      if (icon != null && icon.isNotEmpty) 'icon': icon,
      if (workspaceId != null && workspaceId.isNotEmpty) 'workspace_id': workspaceId,
    };
    for (final entry in fields.entries) {
      await db.putField('project', id, entry.key, entry.value, ts, engine.device);
    }
    return Project(id, {'id': id, ...fields});
  }

  /// A fresh entity id: a v4 UUID, the same shape the server makes.
  static String newId() => const Uuid().v4();
}

/// How much of a repeating task a delete covers.
enum SeriesScope { occurrence, future, all }
