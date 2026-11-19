import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'clock.dart';
import 'db.dart';
import 'models.dart';
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

  Future<void> setCompleted(Task task, bool completed) async {
    final ts = await clock.next();
    await db.putField('task', task.id, 'completed_at',
        completed ? DateTime.now().millisecondsSinceEpoch : null, ts, engine.device);
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
