import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/e2ee/lifecycle.dart';
import 'package:otda/src/e2ee/session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    E2eeSession.persistToKeystore = false;
    E2eeSession.instance.resetForTest();
  });

  tearDown(() => E2eeSession.instance.resetForTest());

  test('enabling encrypts personal content, leaves shared content alone, and disabling reverses it', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    var deletes = 0;
    final wire = <String, Object?>{};
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        if (request.method == 'PUT' && request.url.path == '/api/v1/encryption/keys') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'keys': body}), 201, headers: {'content-type': 'application/json'});
        }
        if (request.method == 'POST' && request.url.path == '/api/v1/sync') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          for (final op in (body['ops'] as List?) ?? const []) {
            if (op is Map) wire['${op['entity']}:${op['entityId']}:${op['field']}'] = op['value'];
          }
          return http.Response('{"cursor":1,"ops":[],"applied":0,"rejected":[]}', 200);
        }
        if (request.method == 'DELETE' && request.url.path == '/api/v1/encryption/keys') {
          deletes++;
          return http.Response('', 204);
        }
        if (request.method == 'POST' && request.url.path == '/api/v1/encryption/purge-history') {
          return http.Response('{"purged":3,"notice":"history purged"}', 200);
        }
        return http.Response('', 204);
      }),
    );
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);

    final personal = await repo.createProject('Personal');
    final personalTask = await repo.createTask(
      'Private title',
      projectId: personal.id,
      extra: {'description': 'a note'},
    );
    final sharedProject = await repo.createProject('Shared');
    final sharedTask = await repo.createTask('Shared title', projectId: sharedProject.id);
    await db.setMeta(
      'sync.memberships',
      jsonEncode([
        {
          'projectId': sharedProject.id,
          'members': [
            {'userId': 'u1', 'role': 'owner'},
            {'userId': 'u2', 'role': 'editor'},
          ],
        },
      ]),
    );
    // Seed the server side with the plaintext first.
    await engine.exchange();
    expect(await db.outboxCount(), 0);

    final lifecycle = E2eeLifecycle(repo: repo, client: client, engine: engine);
    final prepared = lifecycle.prepare('a long passphrase');
    await lifecycle.enable(prepared);
    expect(E2eeSession.instance.enabled, isTrue);
    expect(E2eeSession.instance.unlocked, isTrue);

    String titleWire(String id) => wire['task:$id:title']?.toString() ?? '';
    expect(await _rawField(db, 'task', personalTask.id, 'title'), 'Private title');
    expect(await _rawField(db, 'task', personalTask.id, 'description'), 'a note');
    expect(titleWire(personalTask.id), startsWith('enc:v1:'));
    expect(wire['task:${personalTask.id}:description'], startsWith('enc:v1:'));
    expect(await _rawField(db, 'task', sharedTask.id, 'title'), 'Shared title');
    expect(titleWire(sharedTask.id), 'Shared title');
    expect(await lifecycle.pendingMigration(), isNull);
    expect(await lifecycle.purgeHistory(), 3);

    await lifecycle.disable();
    expect(deletes, 1);
    expect(E2eeSession.instance.enabled, isFalse);
    expect(await _rawField(db, 'task', personalTask.id, 'title'), 'Private title');
    expect(await _rawField(db, 'task', personalTask.id, 'description'), 'a note');
    expect(await _rawField(db, 'task', sharedTask.id, 'title'), 'Shared title');
    expect(titleWire(personalTask.id), 'Private title');

    await db.close();
  });

  test('a second enable is refused by the server record conflict', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        if (request.method == 'PUT') {
          return http.Response(
            '{"error":{"code":"encryption_conflict","message":"already enabled"}}',
            409,
          );
        }
        return http.Response('{"cursor":1,"ops":[],"applied":0}', 200);
      }),
    );
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    final lifecycle = E2eeLifecycle(repo: repo, client: client, engine: engine);
    await expectLater(lifecycle.enable(lifecycle.prepare('a long passphrase')), throwsA(isA<Object>()));
    expect(E2eeSession.instance.enabled, isFalse);
    await db.close();
  });
}

Future<Object?> _rawField(OtdaDb db, String entity, String id, String field) async {
  final row = (await db.allFields()).firstWhere(
    (r) => r['entity'] == entity && r['entity_id'] == id && r['field'] == field,
  );
  return jsonDecode(row['value']! as String);
}
