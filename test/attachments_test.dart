import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/e2ee/attachments.dart';
import 'package:otda/src/e2ee/crypto.dart';
import 'package:otda/src/e2ee/keys.dart';
import 'package:otda/src/e2ee/session.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late OtdaDb db;
  late Repo repo;
  late Directory dir;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  Uint8List? uploaded;
  Uint8List? served;
  var deletes = 0;

  setUp(() async {
    E2eeSession.persistToKeystore = false;
    E2eeSession.instance.resetForTest();
    db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        if (request.method == 'PUT' && request.url.path.contains('/content')) {
          uploaded = request.bodyBytes;
          return http.Response('', 204);
        }
        if (request.method == 'GET' && request.url.path.contains('/content')) {
          return http.Response.bytes(served ?? uploaded ?? const [], 200);
        }
        if (request.method == 'DELETE') {
          deletes++;
          return http.Response('', 204);
        }
        return http.Response('', 204);
      }),
    );
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    repo = Repo(db: db, clock: clock, engine: engine);
    dir = await Directory(p.join('.tmp', 'attachment-test-${DateTime.now().microsecondsSinceEpoch}')).create(recursive: true);
  });

  tearDown(() async {
    E2eeSession.instance.resetForTest();
    if (await dir.exists()) await dir.delete(recursive: true);
    await db.close();
  });

  AttachmentService service() {
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        if (request.method == 'PUT' && request.url.path.contains('/content')) {
          uploaded = request.bodyBytes;
          return http.Response('', 204);
        }
        if (request.method == 'GET' && request.url.path.contains('/content')) {
          return http.Response.bytes(served ?? uploaded ?? const [], 200);
        }
        if (request.method == 'DELETE') {
          deletes++;
          return http.Response('', 204);
        }
        return http.Response('', 204);
      }),
    );
    return AttachmentService(repo: repo, client: client, authorId: 'u1', directoryOverride: () async => dir);
  }

  void enableEncryption() {
    E2eeSession.instance
      ..record = KeyRecord(
        salt: 'c2FsdA',
        iterations: 600000,
        wrappedByPassphrase: 'cGFzcw',
        wrappedByRecovery: 'cmVjb3Y',
        createdAt: 100,
      )
      ..adoptKeyForTest(key);
  }

  test('a personal file is stored encrypted, uploaded as the envelope and opens again', () async {
    enableEncryption();
    final task = await repo.createTask('Taxes');
    final plain = Uint8List.fromList(utf8.encode('hello attachment'));
    final attachment = await service().add(
      taskId: task.id,
      name: 'note.txt',
      mime: 'text/plain',
      bytes: plain,
    );

    expect(attachment.encrypted, isTrue);
    expect(attachment.name, 'note.txt');
    expect(attachment.size, greaterThan(plain.length));
    expect(uploaded, isNotNull);
    expect(uploaded!.sublist(0, 5), utf8.encode('OTAT1'));

    served = uploaded;
    final opened = await service().open(attachment);
    expect(opened.bytes, plain);

    // The local stored bytes are the envelope, not the plaintext.
    final local = await File(p.join(dir.path, 'attachments', '${attachment.id}.bin')).readAsBytes();
    expect(local.sublist(0, 5), utf8.encode('OTAT1'));
    expect(decryptFileBytes(key: key, attachmentId: attachment.id, envelope: local), plain);
  });

  test('a plaintext file is re-uploaded encrypted and back as a new row', () async {
    final task = await repo.createTask('Migrate');
    final plain = Uint8List.fromList(utf8.encode('migrate me'));
    final old = await service().add(taskId: task.id, name: 'm.txt', mime: 'text/plain', bytes: plain);
    expect(old.encrypted, isFalse);

    enableEncryption();
    var progress = <String>[];
    await service().migrate(encrypt: true, onProgress: (done, total) => progress.add('$done/$total'));
    final encrypted = (await repo.attachments(task.id)).single;
    expect(encrypted.id, isNot(old.id));
    expect(encrypted.encrypted, isTrue);
    expect(encrypted.uploadedAt, isNull);
    expect(uploaded!.sublist(0, 5), utf8.encode('OTAT1'));
    expect(progress.last, '1/1');

    served = uploaded;
    expect((await service().open(encrypted)).bytes, plain);

    await service().migrate(encrypt: false);
    final back = (await repo.attachments(task.id)).single;
    expect(back.encrypted, isFalse);
    expect(uploaded, plain);
  });

  test('a shared project keeps the file plaintext even on an encrypted account', () async {
    enableEncryption();
    final project = await repo.createProject('Shared');
    final task = await repo.createTask('Shared file', projectId: project.id);
    await db.setMeta('sync.memberships', jsonEncode([
      {
        'projectId': project.id,
        'members': [
          {'userId': 'u1', 'role': 'owner'},
          {'userId': 'u2', 'role': 'editor'},
        ],
      },
    ]));
    final plain = Uint8List.fromList(utf8.encode('shared bytes'));
    final attachment = await service().add(taskId: task.id, name: 's.txt', mime: 'text/plain', bytes: plain);
    expect(attachment.encrypted, isFalse);
    expect(uploaded, plain);
    served = uploaded;
    expect((await service().open(attachment)).bytes, plain);
  });

  test('a locked device refuses to add or open an encrypted file', () async {
    E2eeSession.instance.record = KeyRecord(
      salt: 'c2FsdA',
      iterations: 600000,
      wrappedByPassphrase: 'cGFzcw',
      wrappedByRecovery: 'cmVjb3Y',
      createdAt: 100,
    );
    final task = await repo.createTask('Locked');
    await expectLater(
      service().add(taskId: task.id, name: 'x.txt', mime: 'text/plain', bytes: Uint8List.fromList([1])),
      throwsA(isA<AttachmentError>().having((e) => e.code, 'code', 'locked')),
    );
  });

  test('a tampered download is refused, and removing tombstones the row', () async {
    final task = await repo.createTask('Plain');
    final plain = Uint8List.fromList(utf8.encode('plain bytes'));
    final attachment = await service().add(taskId: task.id, name: 'p.txt', mime: 'text/plain', bytes: plain);
    served = Uint8List.fromList(utf8.encode('tampered'));
    await expectLater(
      service().open(attachment),
      throwsA(isA<AttachmentError>().having((e) => e.code, 'code', 'check_failed')),
    );

    await service().remove(attachment);
    expect(deletes, 1);
    expect(await repo.attachments(task.id), isEmpty);
  });
}
