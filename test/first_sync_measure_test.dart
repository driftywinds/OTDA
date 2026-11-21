@Tags(['integration'])
library;

// Measures a real first copy against the v1.5.0 server seeded by perfseed:
//
//   flutter test test/first_sync_measure_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// The 10,000-task fixture is 105,340 operations. A first copy used to stop at
// 20 pages (20,000 ops) and wait for the next 30 s timer tick, which is why a
// large account looked half-empty for minutes. This asserts the one-run gate:
// every page in one exchange, progress reaching 1.0, and the completeness flag.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const server = String.fromEnvironment(
  'OT_SERVER',
  defaultValue: 'http://127.0.0.1:18081',
);
const email = String.fromEnvironment(
  'OT_EMAIL',
  defaultValue: 'perf@example.com',
);
const password = String.fromEnvironment(
  'OT_PASSWORD',
  defaultValue: 'perf-password-10k',
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the whole first copy arrives in one gated exchange', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(
      client,
      email: email,
      password: password,
    );
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');
    expect(outcome.challenge, isNull);

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    expect(engine.fullSyncDone, isFalse);

    final progress = <SyncProgress>[];
    final started = DateTime.now();
    final result = await engine.exchange(
      fullSync: true,
      onProgress: progress.add,
    );
    final elapsed = DateTime.now().difference(started);

    final tasks = await repo.tasks();
    final projects = await repo.projects();

    // ignore: avoid_print
    print(
      'first copy: ${result.pulled} ops, ${result.pages} pages, '
      '${elapsed.inMilliseconds} ms, ${tasks.length} live tasks, '
      '${projects.length} projects, gated=${engine.fullSyncDone}',
    );
    if (progress.isNotEmpty) {
      // ignore: avoid_print
      print(
        'progress: first=${progress.first.done}/${progress.first.total} '
        'last=${progress.last.done}/${progress.last.total} '
        'fraction=${progress.last.fraction}',
      );
    }

    expect(result.pages, greaterThan(1));
    expect(result.rejected, 0);
    expect(engine.fullSyncDone, isTrue);
    expect(engine.cursorForTest, greaterThan(0));
    expect(tasks.length, 9500, reason: '6000 open + 3500 completed live tasks');
    expect(tasks.where((t) => t.isCompleted).length, 3500);
    expect(projects.length, 60);
    expect(progress, isNotEmpty);
    expect(progress.last.fraction, 1.0);

    // A second copy starts from the stored cursor and has nothing to pull.
    final second = await engine.exchange(fullSync: true);
    expect(second.pulled, 0);
    expect(second.pages, 1);

    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
