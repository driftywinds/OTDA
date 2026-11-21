@Tags(['integration'])
library;

// Activity and history against a real v1.5.0 server:
//
//   flutter test test/activity_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// The cross-project feed is derived from shared scopes, so the seeded owner has
// events in the three shared projects. A personal task never reaches the feed,
// but its own activity and history do.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/activity_feed.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18081');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'perf@example.com');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'perf-password-10k');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the feed pages, and a personal task keeps its own activity and history', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');

    const feed = ActivityService();
    final first = await feed.feed(client, limit: 2);
    expect(first.events, isNotEmpty, reason: 'the seeded shared projects should have activity');
    expect(first.events.length, lessThanOrEqualTo(2));
    expect(first.events.first.id, isNotEmpty);
    if (first.more) {
      final second = await feed.feed(client, cursor: first.cursor, limit: 2);
      expect(second.events.map((e) => e.id), isNot(contains(first.events.first.id)));
    }

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    final head = await client.post('/api/v1/sync', body: {
      'device': engine.device,
      'cursor': 0,
      'ops': const <Object>[],
      'features': const ['push_only'],
    }) as Map<String, dynamic>;
    await db.setMetaInt('sync.cursor', (head['cursor'] as num).toInt());
    await db.setMetaInt('sync.full', 1);
    await engine.open();

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final task = await repo.createTask('Activity test $stamp');
    await engine.exchange();
    // The server folds one actor's ops on one entity within 5 s into one event;
    // wait so this completion is its own event rather than part of the creation.
    await Future<void>.delayed(const Duration(seconds: 6));
    await repo.setCompleted(task, true);
    await engine.exchange();

    final history = await const HistoryService().task(client, task.id);
    expect(history.changeSets, isNotEmpty);
    final fields = [for (final set in history.changeSets) for (final change in set.changes) change.field];
    expect(fields, containsAll(['title', 'completed_at']));

    final taskActivity = await feed.forTask(client, task.id);
    expect(taskActivity.events, isNotEmpty);
    expect(taskActivity.events.map((e) => e.kind), contains('completed'));

    // A personal task is not in the shared-project feed.
    final feedAgain = await feed.feed(client, limit: 100);
    expect(feedAgain.events.map((e) => e.taskId), isNot(contains(task.id)));

    // Cleaning up the task also cleans its activity/history.
    await repo.trash(task);
    await engine.exchange();
    await repo.purgeTask((await repo.trashedTasks()).firstWhere((t) => t.id == task.id));

    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
