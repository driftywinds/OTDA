@Tags(['integration'])
library;

// Integration test for the sync engine against a real OpenTodo server.
//
//   flutter test test/sync_exchange_test.dart
//
// Defaults to the local v1.5.0 server started from .tmp/server; override with
//   --dart-define=OT_SERVER=http://127.0.0.1:18080
//   --dart-define=OT_EMAIL=... --dart-define=OT_PASSWORD=...
// The test is skipped when the server does not answer.
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

  late ApiClient client;
  late OtdaDb db;
  late SyncEngine engine;
  late Repo repo;

  setUp(() async {
    client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');

    db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    repo = Repo(db: db, clock: clock, engine: engine);
  });

  tearDown(() async {
    await db.close();
    client.close();
  });

  test('a local task reaches the server', () async {
    final title = 'OTDA local→server ${DateTime.now().microsecondsSinceEpoch}';
    final task = await repo.createTask(title);
    expect(task.title, title);

    final result = await engine.exchange();
    expect(result.ok, isTrue, reason: 'rejected: ${result.rejected}');

    final tasks = await client.get('/api/v1/tasks') as Map<String, dynamic>;
    final titles = ((tasks['tasks'] as List?) ?? const [])
        .whereType<Map>()
        .map((t) => t['title']?.toString())
        .toList();
    expect(titles, contains(title), reason: 'the server does not have the task we pushed');
  });

  test('a server task reaches the device', () async {
    final title = 'OTDA server→local ${DateTime.now().microsecondsSinceEpoch}';
    await client.post('/api/v1/tasks', body: {'title': title});

    await engine.exchange();
    final tasks = await repo.tasks();
    expect(tasks.map((t) => t.title), contains(title));
  });

  test('completing offline converges after one exchange', () async {
    final title = 'OTDA complete ${DateTime.now().microsecondsSinceEpoch}';
    final task = await repo.createTask(title);
    await engine.exchange();

    await repo.setCompleted(task, true);
    await engine.exchange();

    final json = await client.get('/api/v1/tasks/${task.id}') as Map<String, dynamic>;
    expect(json['completed_at'], isNotNull, reason: 'the server did not record the completion');
  });

  test('deleting locally removes the task on the server', () async {
    final title = 'OTDA trash ${DateTime.now().microsecondsSinceEpoch}';
    final task = await repo.createTask(title);
    await engine.exchange();

    await repo.trash(task);
    await engine.exchange();

    final tasks = await client.get('/api/v1/tasks') as Map<String, dynamic>;
    final titles = ((tasks['tasks'] as List?) ?? const [])
        .whereType<Map>()
        .map((t) => t['title']?.toString())
        .toList();
    expect(titles, isNot(contains(title)));
  });

  test('the cursor advances and the second exchange is a no-op', () async {
    await engine.exchange();
    final second = await engine.exchange();
    expect(second.pages, greaterThanOrEqualTo(1));
    // Nothing new to apply or push in the steady state.
    expect(second.applied, 0);
    expect(second.rejected, 0);
  });
}
