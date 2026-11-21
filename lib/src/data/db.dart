import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// The local replica: one row per entity field, with the clock that wrote it.
///
/// This mirrors the server's model on purpose — the same per-field
/// last-writer-wins comparison decides what a device keeps, so a device that
/// syncs and a device that never lost the connection end up identical.
class OtdaDb {
  OtdaDb._(this._db);

  final Database _db;

  static Future<OtdaDb> open({String? path}) async {
    final file = path ?? p.join(await databaseFactory.getDatabasesPath(), 'otda.db');
    final db = await databaseFactory.openDatabase(
      file,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE fields (
              entity TEXT NOT NULL,
              entity_id TEXT NOT NULL,
              field TEXT NOT NULL,
              value TEXT NOT NULL,
              ts INTEGER NOT NULL,
              device TEXT NOT NULL,
              PRIMARY KEY (entity, entity_id, field)
            )''');
          await db.execute('CREATE INDEX fields_entity ON fields(entity, entity_id)');
          await db.execute('''
            CREATE TABLE outbox (
              id TEXT PRIMARY KEY,
              entity TEXT NOT NULL,
              entity_id TEXT NOT NULL,
              field TEXT NOT NULL,
              value TEXT NOT NULL,
              ts INTEGER NOT NULL,
              device TEXT NOT NULL
            )''');
          await db.execute('CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
        },
      ),
    );
    return OtdaDb._(db);
  }

  Future<void> close() => _db.close();

  // ---- meta -------------------------------------------------------------

  Future<String?> meta(String key) async {
    final rows = await _db.query('meta', where: 'k = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  Future<int> metaInt(String key, {int fallback = 0}) async =>
      int.tryParse(await meta(key) ?? '') ?? fallback;

  Future<void> setMeta(String key, String value) => _db.insert('meta', {'k': key, 'v': value},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setMetaInt(String key, int value) => setMeta(key, '$value');

  Future<void> deleteMeta(String key) => _db.delete('meta', where: 'k = ?', whereArgs: [key]);

  // ---- the winner rule --------------------------------------------------

  /// Applies one field value if it wins: `(ts, device)` greater than the stored
  /// pair. Returns true when it was written.
  Future<bool> applyField(
    String entity,
    String entityId,
    String field,
    String valueJson,
    int ts,
    String device,
  ) async {
    final current = await _db.query('fields',
        columns: ['ts', 'device'],
        where: 'entity = ? AND entity_id = ? AND field = ?',
        whereArgs: [entity, entityId, field],
        limit: 1);
    if (current.isNotEmpty) {
      final curTs = current.first['ts'] as int;
      final curDevice = current.first['device'] as String;
      final wins = ts > curTs || (ts == curTs && device.compareTo(curDevice) > 0);
      if (!wins) return false;
    }
    await _db.insert(
      'fields',
      {'entity': entity, 'entity_id': entityId, 'field': field, 'value': valueJson, 'ts': ts, 'device': device},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<bool> applyOp(Map<String, dynamic> op) => applyField(
        op['entity'] as String,
        op['entityId'] as String,
        op['field'] as String,
        jsonEncode(op['value']),
        (op['ts'] as num).toInt(),
        op['device'] as String,
      );

  /// Applies a pulled page in one transaction. A page is up to 1000 ops; one
  /// commit per op made a first copy take half a minute.
  ///
  /// The winner check does one read per entity type for the whole page instead
  /// of one per op: on the 10,000-task fixture a page touches about a hundred
  /// entities and a thousand fields, so this removes ~1,000 round trips per
  /// page. The inserts go through one batch for the same reason.
  Future<int> applyOps(List<Map<String, dynamic>> ops) async {
    if (ops.isEmpty) return 0;
    var written = 0;
    await _db.transaction((txn) async {
      final current = <String, (int, String)>{};
      final byEntity = <String, Set<String>>{};
      for (final op in ops) {
        final entity = op['entity'] as String;
        byEntity.putIfAbsent(entity, () => <String>{}).add(op['entityId'] as String);
      }
      for (final entry in byEntity.entries) {
        final ids = entry.value.toList();
        for (var start = 0; start < ids.length; start += 400) {
          final chunk = ids.sublist(start, start + 400 > ids.length ? ids.length : start + 400);
          final rows = await txn.query(
            'fields',
            columns: ['entity_id', 'field', 'ts', 'device'],
            where: 'entity = ? AND entity_id IN (${List.filled(chunk.length, '?').join(',')})',
            whereArgs: [entry.key, ...chunk],
          );
          for (final row in rows) {
            current[_fieldKey(entry.key, row['entity_id'] as String, row['field'] as String)] =
                (row['ts'] as int, row['device'] as String);
          }
        }
      }

      final batch = txn.batch();
      for (final op in ops) {
        final entity = op['entity'] as String;
        final entityId = op['entityId'] as String;
        final field = op['field'] as String;
        final ts = (op['ts'] as num).toInt();
        final device = op['device'] as String;
        final key = _fieldKey(entity, entityId, field);
        final stored = current[key];
        if (stored != null && !(ts > stored.$1 || (ts == stored.$1 && device.compareTo(stored.$2) > 0))) {
          continue;
        }
        current[key] = (ts, device);
        batch.insert(
          'fields',
          {
            'entity': entity,
            'entity_id': entityId,
            'field': field,
            'value': jsonEncode(op['value']),
            'ts': ts,
            'device': device,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        written++;
      }
      await batch.commit(noResult: true);
    });
    return written;
  }

  static String _fieldKey(String entity, String entityId, String field) =>
      '$entity\u0000$entityId\u0000$field';

  Future<int> maxTs() async {
    final rows = await _db.rawQuery('SELECT MAX(ts) AS m FROM fields');
    return (rows.first['m'] as int?) ?? 0;
  }

  // ---- read -------------------------------------------------------------

  /// Every live (not tombstoned) entity of one type, as decoded field maps.
  Future<List<Map<String, Object?>>> entities(String entity, {bool includeDeleted = false}) async {
    final rows = await _db.query('fields', where: 'entity = ?', whereArgs: [entity]);
    final byId = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final id = row['entity_id'] as String;
      final map = byId.putIfAbsent(id, () => <String, Object?>{'id': id});
      map[row['field'] as String] = _decode(row['value'] as String);
    }
    if (includeDeleted) return byId.values.toList();
    return byId.values.where((e) => e['deleted_at'] == null).toList();
  }

  Future<Map<String, Object?>?> entity(String entity, String id) async {
    final rows = await _db.query('fields',
        where: 'entity = ? AND entity_id = ?', whereArgs: [entity, id]);
    if (rows.isEmpty) return null;
    final map = <String, Object?>{'id': id};
    for (final row in rows) {
      map[row['field'] as String] = _decode(row['value'] as String);
    }
    return map;
  }

  static Object? _decode(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      return json; // a value that is not JSON is kept as text
    }
  }

  // ---- write ------------------------------------------------------------

  /// Called after a field write, once the row is durable. The app uses it to
  /// rebuild the widget and re-arm reminders, so no caller has to remember to.
  void Function()? onWrite;


  Future<void> putField(String entity, String entityId, String field, Object? value, int ts, String device) async {
    final json = jsonEncode(value);
    await _db.transaction((txn) async {
      await txn.insert(
        'fields',
        {'entity': entity, 'entity_id': entityId, 'field': field, 'value': json, 'ts': ts, 'device': device},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('outbox', {
        'id': _uuid(),
        'entity': entity,
        'entity_id': entityId,
        'field': field,
        'value': json,
        'ts': ts,
        'device': device,
      });
    });
    onWrite?.call();
  }

  /// Queues a field operation without changing the local value. The migration
  /// uses it to put ciphertext on the wire while the replica keeps plaintext.
  Future<void> enqueueField(String entity, String entityId, String field, Object? value, int ts, String device) async {
    await _db.insert('outbox', {
      'id': _uuid(),
      'entity': entity,
      'entity_id': entityId,
      'field': field,
      'value': jsonEncode(value),
      'ts': ts,
      'device': device,
    });
  }

  /// Every stored field, for the one-time decrypt after an unlock.
  Future<List<Map<String, Object?>>> allFields() => _db.query('fields');

  /// Replaces a stored value **without** queueing an operation: the server already
  /// holds the ciphertext, so a local plaintext is a rendering change, not an edit.
  Future<void> setLocalValue(String entity, String entityId, String field, Object? value) async {
    await _db.update(
      'fields',
      {'value': jsonEncode(value)},
      where: 'entity = ? AND entity_id = ? AND field = ?',
      whereArgs: [entity, entityId, field],
    );
  }

  Future<List<Map<String, Object?>>> pendingOps({int limit = 1000}) =>
      _db.query('outbox', orderBy: 'ts ASC', limit: limit);

  /// How many queued writes are still waiting for an exchange.
  Future<int> outboxCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM outbox');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Every stored field, for the re-seed after a server restore.
  Future<List<Map<String, Object?>>> rawAllFields() => _db.query('fields');

  /// Queues an already-applied field again, keeping its stored clock.
  Future<void> queueExistingField(Map<String, Object?> row) async {
    final already = await _db.query('outbox',
        where: 'entity = ? AND entity_id = ? AND field = ? AND ts = ?',
        whereArgs: [row['entity'], row['entity_id'], row['field'], row['ts']],
        limit: 1);
    if (already.isNotEmpty) return;
    await _db.insert('outbox', {
      'id': _uuid(),
      'entity': row['entity'],
      'entity_id': row['entity_id'],
      'field': row['field'],
      'value': row['value'],
      'ts': row['ts'],
      'device': row['device'],
    });
  }

  Future<void> dropOutbox(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final batch = _db.batch();
    for (final id in ids) {
      batch.delete('outbox', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Deletes a purged entity locally and forgets any queued write for it.
  Future<void> purgeEntity(String entity, String id) async {
    await _db.transaction((txn) async {
      await txn.delete('fields', where: 'entity = ? AND entity_id = ?', whereArgs: [entity, id]);
      await txn.delete('outbox', where: 'entity = ? AND entity_id = ?', whereArgs: [entity, id]);
    });
  }

  static String _uuid() => const Uuid().v4();
}
