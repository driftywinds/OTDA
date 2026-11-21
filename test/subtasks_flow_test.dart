@Tags(['integration'])
library;

// Subtasks against a real v1.5.0 server:
//
//   flutter test test/subtasks_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// Creates a two-level subtree, completes the parent (which must send one
// completed_at op per open descendant), reopens only the parent, then moves the
// parent to another project (every descendant follows).
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
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

  test('subtask completion, reopening and a project move reach the server', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    // Only this test's rows are needed: start at the server head.
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
    final source = await repo.createProject('Subtask source $stamp');
    final target = await repo.createProject('Subtask target $stamp');
    final parent = await repo.createTask('Parent $stamp', projectId: source.id);
    final child = await repo.createSubtask(parent, 'Child $stamp');
    final grandchild = await repo.createSubtask(child, 'Grandchild $stamp');
    await engine.exchange();

    Future<Map<String, dynamic>?> serverTask(String id) async {
      final json = await client.get('/api/v1/tasks', query: {
        'include_deleted': 'true',
        'project_id': source.id,
      }) as Map<String, dynamic>;
      return ((json['tasks'] as List?) ?? const [])
          .whereType<Map>()
          .map((row) => row.cast<String, dynamic>())
          .where((row) => row['id'] == id)
          .firstOrNull;
    }

    // Completing the parent sends one completed_at for each open descendant.
    await repo.setCompleted(parent, true);
    await engine.exchange();
    expect((await serverTask(parent.id))?['completed_at'], isNotNull);
    expect((await serverTask(child.id))?['completed_at'], isNotNull);
    expect((await serverTask(grandchild.id))?['completed_at'], isNotNull);

    // Reopening the parent leaves the descendants done.
    await repo.setCompleted((await repo.task(parent.id))!, false);
    await engine.exchange();
    expect((await serverTask(parent.id))?['completed_at'], isNull);
    expect((await serverTask(child.id))?['completed_at'], isNotNull);

    // A project move carries the whole subtree.
    await repo.moveToProject((await repo.task(parent.id))!, target.id);
    await engine.exchange();
    final moved = await client.get('/api/v1/tasks', query: {
      'include_deleted': 'true',
      'project_id': target.id,
    }) as Map<String, dynamic>;
    final ids = [
      for (final row in (moved['tasks'] as List?) ?? const [])
        if (row is Map) row['id']?.toString(),
    ];
    expect(ids, containsAll([parent.id, child.id, grandchild.id]));

    // Clean up: delete the two projects and their tasks for good.
    await repo.trashProject(source.id);
    await repo.trashProject(target.id);
    await engine.exchange();
    final projects = await client.get('/api/v1/projects', query: {'include_deleted': 'true'})
        as Map<String, dynamic>;
    for (final id in [source.id, target.id]) {
      final row = ((projects['projects'] as List?) ?? const [])
          .whereType<Map>()
          .firstWhere((p) => p['id'] == id);
      expect(row['deleted_at'], isNotNull);
    }

    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
