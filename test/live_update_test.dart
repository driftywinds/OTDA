@Tags(['integration'])
library;

// The live channel: a change made by another device must land without waiting
// for the 30 s poll.
//
//   flutter test test/live_update_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18080');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'dev@otda.local');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'otda-test-passphrase-2026');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('an SSE wake-up pulls a change made elsewhere', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    await engine.exchange(); // first copy

    await engine.startLive();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Another device writes straight to the server.
    final title = 'OTDA live ${DateTime.now().microsecondsSinceEpoch}';
    await client.post('/api/v1/tasks', body: {'title': title});

    // Wait for it to appear without calling exchange() ourselves.
    final started = DateTime.now();
    var found = false;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if ((await repo.tasks()).any((t) => t.title == title)) {
        found = true;
        break;
      }
    }
    final elapsed = DateTime.now().difference(started);
    engine.stopLive();
    await db.close();
    client.close();

    expect(found, isTrue, reason: 'the live channel did not wake the device within 6 s');
    expect(elapsed.inSeconds, lessThan(5), reason: 'took ${elapsed.inMilliseconds} ms — is SSE connected?');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
