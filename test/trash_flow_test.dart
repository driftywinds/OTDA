@Tags(['integration'])
library;

// The Trash against a real v1.5.0 server:
//
//   flutter test test/trash_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// Creates a project with a task and a subtask, deletes/restores the subtree,
// deletes/restores the project, then purges a task and empties the Trash. The
// routes are the server's: DELETE /tasks/{id}/purge, /projects/{id}/purge and
// POST /trash/purge.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
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

  test('delete, restore and purge round-trip with the server', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    // This test only needs the rows it creates. Start at the server's head so a
    // 108k-op fixture is not copied first; `push_only` answers the head cursor.
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
    final project = await repo.createProject('Trash test $stamp');
    final task = await repo.createTask('Task $stamp', projectId: project.id);
    final child = await repo.createTask('Child $stamp', projectId: project.id, extra: {'parent_id': task.id});
    await engine.exchange();

    // Delete the subtree, push, and check the server's tombstones.
    await repo.trash(task);
    await engine.exchange();
    // The single-item GET hides a tombstone (404); the collection can include it.
    Future<Map<String, dynamic>?> serverTask(String id) async {
      final json = await client.get('/api/v1/tasks', query: {
        'include_deleted': 'true',
        'project_id': project.id,
      }) as Map<String, dynamic>;
      return ((json['tasks'] as List?) ?? const [])
          .whereType<Map>()
          .map((row) => row.cast<String, dynamic>())
          .where((row) => row['id'] == id)
          .firstOrNull;
    }

    expect((await serverTask(task.id))?['deleted_at'], isNotNull);
    expect((await serverTask(child.id))?['deleted_at'], isNotNull);
    expect((await repo.tasks()).map((t) => t.id), isNot(contains(task.id)));

    // Restore the subtree: a put back from the Trash is a field write.
    final trashed = (await repo.trashedTasks()).where((t) => t.id == task.id).single;
    await repo.restoreTask(trashed);
    await engine.exchange();
    final restored = await client.get('/api/v1/tasks/${task.id}') as Map<String, dynamic>;
    expect(restored['deleted_at'], isNull);
    expect((await repo.tasks()).map((t) => t.id), containsAll([task.id, child.id]));

    // A project in the Trash hides its tasks; restoring it is one op.
    await repo.trashProject(project.id);
    await engine.exchange();
    expect((await repo.tasks()).map((t) => t.id), isNot(contains(task.id)));
    final projectsJson = await client.get('/api/v1/projects', query: {'include_deleted': 'true'})
        as Map<String, dynamic>;
    final gone = ((projectsJson['projects'] as List?) ?? const [])
        .whereType<Map>()
        .map((row) => row.cast<String, dynamic>())
        .where((row) => row['id'] == project.id)
        .firstOrNull;
    expect(gone?['deleted_at'], isNotNull);
    final trashedProject = (await repo.trashedProjects()).where((p) => p.id == project.id).single;
    await repo.restoreProject(trashedProject);
    await engine.exchange();
    expect((await repo.tasks()).map((t) => t.id), contains(task.id));

    // Purge one task for good: the route requires it to be in the Trash first.
    await repo.trash(task);
    await engine.exchange();
    await repo.purgeTask(task);
    await expectLater(client.get('/api/v1/tasks/${task.id}'), throwsA(isA<ApiException>()));
    expect(await repo.task(task.id), isNull);

    // Purge the extra task too (empty-trash is covered by the data test; this
    // fixture has 500 trashed tasks and emptying it would destroy the fixture).
    final extra = await repo.createTask('Purge me $stamp');
    await engine.exchange();
    await repo.trash(extra);
    await engine.exchange();
    final trashedExtra = (await repo.trashedTasks()).where((t) => t.id == extra.id).single;
    await repo.purgeTask(trashedExtra);
    await expectLater(client.get('/api/v1/tasks/${extra.id}'), throwsA(isA<ApiException>()));

    // The project is live again; purge it for a clean fixture.
    await repo.trashProject(project.id);
    await engine.exchange();
    final goneProject = (await repo.trashedProjects()).where((p) => p.id == project.id).single;
    await repo.purgeProject(goneProject);
    await expectLater(client.get('/api/v1/projects/${project.id}'), throwsA(isA<ApiException>()));

    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
