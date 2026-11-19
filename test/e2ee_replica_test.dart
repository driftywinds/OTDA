// The bug this pins: the key unwrapped, the toast said unlocked, and every list
// still showed enc:v1: because the replica was filled before the device was
// unlocked and only *new* operations were decrypted.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/e2ee/crypto.dart';
import 'package:otda/src/e2ee/session.dart';
import 'package:otda/src/util/numbers.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late OtdaDb db;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

  setUp(() async {
    final path = p.join(
      Directory.systemTemp.path,
      'otda_e2ee_replica_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await OtdaDb.open(path: path);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedField(String entity, String id, String field, Object? value) async {
    await db.putField(entity, id, field, value, 1, 'device');
  }

  Future<Object?> readField(String entity, String id, String field) async {
    final rows = await db.allFields();
    final row = rows.firstWhere(
      (r) => r['entity'] == entity && r['entity_id'] == id && r['field'] == field,
    );
    return jsonDecode(row['value']! as String);
  }

  test('unlocking rewrites the stored ciphertext as plaintext, with no new op', () async {
    final cipher = encryptValue(
      key: key,
      entity: 'task',
      entityId: 't1',
      field: 'title',
      plaintext: 'Dentist',
    );
    await seedField('task', 't1', 'title', cipher);
    // A plaintext field must survive untouched.
    await seedField('task', 't1', 'priority', 2);
    // Nothing may be queued: the server already holds the ciphertext.
    await db.dropOutbox((await db.pendingOps()).map((r) => r['id'] as String).toList());

    E2eeSession.instance.adoptKeyForTest(key);
    final opened = await E2eeSession.instance.openLocalReplica(db);

    expect(opened, 1);
    expect(await readField('task', 't1', 'title'), 'Dentist');
    expect(await readField('task', 't1', 'priority'), 2);
    expect(await db.pendingOps(), isEmpty);
  });

  test('a ciphertext bound to another field is left alone, not mangled', () async {
    final cipher = encryptValue(
      key: key,
      entity: 'task',
      entityId: 't1',
      field: 'title',
      plaintext: 'Dentist',
    );
    // Moved to description: the binding no longer matches.
    await seedField('task', 't1', 'description', cipher);
    await db.dropOutbox((await db.pendingOps()).map((r) => r['id'] as String).toList());

    E2eeSession.instance.adoptKeyForTest(key);
    final opened = await E2eeSession.instance.openLocalReplica(db);

    expect(opened, 0);
    expect(await readField('task', 't1', 'description'), cipher);
  });

  test('a title the server sent as a string is still read as a number', () {
    expect(numOrNull('1633024800000'), 1633024800000);
    expect(numOrNull(42), 42);
    expect(numOrNull('2021-09-30T18:00:00Z'), isA<int>());
    expect(numOrNull(''), isNull);
    expect(numOrNull(null), isNull);
    expect(numOrNull('not a number'), isNull);
  });
}
