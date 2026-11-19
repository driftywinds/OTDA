import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'clock.dart';
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

  Future<List<Task>> tasks() async =>
      (await db.entities('task')).map((e) => Task(e['id'] as String, e)).toList();

  Future<List<Project>> projects() async =>
      (await db.entities('project')).map((e) => Project(e['id'] as String, e)).toList();

  Future<List<Label>> labels() async =>
      (await db.entities('label')).map((e) => Label(e['id'] as String, e)).toList();

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

  /// Marks one occurrence done.
  ///
  /// A plain task gets `completed_at` and is finished. A repeating one is a
  /// series: the occurrence in front of you becomes its own record (what the web
  /// client writes) and the series moves to its next date, so a daily task comes
  /// back tomorrow instead of disappearing. Only when the series has run out does
  /// the series itself complete, which is what the web does too.
  Future<void> setCompleted(Task task, bool completed) async {
    final raw = task.raw['recurrence']?.toString() ?? '';
    final recurring = raw.isNotEmpty && rules.parseRule(raw).ok;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (!recurring) {
      final ts = await clock.next();
      await db.putField('task', task.id, 'completed_at', completed ? now : null, ts, engine.device);
      return;
    }

    final today = _todayString();
    final date = occurrenceDateOf(task, today);

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

    final finished = await _occurrenceCount(task.id);
    final next = nextOccurrenceAfterCompletion(task, finished, today);
    if (next == null) {
      // The end condition is reached: the series completes like a plain task.
      final ts = await clock.next();
      await db.putField('task', task.id, 'completed_at', now, ts, engine.device);
      return;
    }

    final ts = await clock.next();
    final recordId = occurrenceIdOf(task.id, date);
    for (final entry in occurrenceFields(task, date, now, today).entries) {
      await db.putField('task', recordId, entry.key, entry.value, ts, engine.device);
    }
    for (final entry in movedDates(task, next, today).entries) {
      await db.putField('task', task.id, entry.key, entry.value, ts, engine.device);
    }
  }

  /// How many occurrences of this series are already finished, for a `for N times`
  /// rule.
  Future<int> _occurrenceCount(String seriesId) async {
    final rows = await db.entities('task');
    return rows.where((row) => row['series_id']?.toString() == seriesId && row['deleted_at'] == null).length;
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> trash(Task task) async {
    final ts = await clock.next();
    await db.putField('task', task.id, 'deleted_at', DateTime.now().millisecondsSinceEpoch, ts, engine.device);
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

  Future<Project> createProject(String name, {String? color, String? icon}) async {
    final id = newId();
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fields = <String, Object?>{
      'name': name.trim(),
      'created_at': now,
      'position': now.toDouble(),
      if (color != null && color.isNotEmpty) 'color': color,
      if (icon != null && icon.isNotEmpty) 'icon': icon,
    };
    for (final entry in fields.entries) {
      await db.putField('project', id, entry.key, entry.value, ts, engine.device);
    }
    return Project(id, {'id': id, ...fields});
  }

  /// A fresh entity id: a v4 UUID, the same shape the server makes.
  static String newId() => const Uuid().v4();
}
