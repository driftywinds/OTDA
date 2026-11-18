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

  Future<Project> createProject(String name) async {
    final id = newId();
    final ts = await clock.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fields = <String, Object?>{
      'name': name.trim(),
      'created_at': now,
      'position': now.toDouble(),
    };
    for (final entry in fields.entries) {
      await db.putField('project', id, entry.key, entry.value, ts, engine.device);
    }
    return Project(id, {'id': id, ...fields});
  }

  /// A fresh entity id: a v4 UUID, the same shape the server makes.
  static String newId() => const Uuid().v4();
}
