// Pulls the whole log of a real server into a fresh replica — read-only.
//
//   flutter test test/remote_pull_test.dart --dart-define=OT_SERVER=https://… --dart-define=OT_TOKEN=ot_…
//
// Proves the engine handles a real dataset (an imported one, typically) and
// reports what it cost. Nothing is written to the server.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';

const server = String.fromEnvironment('OT_SERVER', defaultValue: '');
const token = String.fromEnvironment('OT_TOKEN', defaultValue: '');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('pull a real server into a fresh replica', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    await const AuthService().withToken(client, token);

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);

    final started = DateTime.now();
    var total = 0;
    var pages = 0;
    for (var round = 0; round < 100; round++) {
      final before = engine.hasCachedCursor ? engine.cursorForTest : -1;
      final result = await engine.exchange();
      total += result.pulled;
      pages += result.pages;
      if (result.pulled == 0 && result.pages <= 1) break;
      if (engine.cursorForTest == before) break;
    }
    final elapsed = DateTime.now().difference(started);

    final tasks = await repo.tasks();
    final projects = await repo.projects();
    final open = tasks.where((t) => !t.isCompleted).length;
    stdout.writeln('pulled $total ops in $pages page(s) over ${elapsed.inMilliseconds} ms');
    stdout.writeln('replica: ${tasks.length} tasks ($open open), ${projects.length} projects');
    stdout.writeln('cursor: ${engine.cursorForTest}, pending: ${engine.pending}');

    expect(tasks, isNotEmpty, reason: 'the replica is empty — is the token scoped to a workspace?');
    expect(engine.pending, 0, reason: 'a read-only pull must not queue ops');
    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 10)),
      skip: server.isEmpty || token.isEmpty
          ? 'needs --dart-define=OT_SERVER=… --dart-define=OT_TOKEN=…'
          : false);
}
