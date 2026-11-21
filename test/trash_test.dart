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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late OtdaDb db;
  late Repo repo;
  late List<http.Request> requests;

  setUp(() async {
    requests = [];
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({'purged': <String, int>{}}), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    repo = Repo(db: db, clock: clock, engine: engine);
  });

  tearDown(() async => db.close());

  test('deleting a task tombstones its subtree and restoring brings it back', () async {
    final project = await repo.createProject('Garden');
    final parent = await repo.createTask('Mow', projectId: project.id);
    final child = await repo.createTask('Edges', projectId: project.id, extra: {'parent_id': parent.id});
    final other = await repo.createTask('Buy seeds', projectId: project.id);

    await repo.trash(parent);
    expect((await repo.tasks()).map((t) => t.id), isNot(contains(parent.id)));
    expect((await repo.tasks()).map((t) => t.id), isNot(contains(child.id)));
    expect((await repo.tasks()).map((t) => t.id), contains(other.id));
    expect((await repo.trashedTasks()).map((t) => t.id), containsAll([parent.id, child.id]));

    await repo.restoreTask(parent);
    final live = (await repo.tasks()).map((t) => t.id).toSet();
    expect(live, containsAll([parent.id, child.id]));
    expect(await repo.trashedTasks(), isEmpty);
  });

  test('a project in the Trash hides its tasks and restoring it brings them back', () async {
    final project = await repo.createProject('Garden');
    final task = await repo.createTask('Mow', projectId: project.id);

    await repo.trashProject(project.id);
    expect((await repo.tasks()).map((t) => t.id), isNot(contains(task.id)));
    expect((await repo.trashedProjects()).map((p) => p.id), contains(project.id));

    await repo.restoreProject((await repo.trashedProjects()).single);
    expect((await repo.tasks()).map((t) => t.id), contains(task.id));
    expect(await repo.trashedProjects(), isEmpty);
  });

  test('restoring a task of a trashed project puts it in the Inbox', () async {
    final project = await repo.createProject('Garden');
    final task = await repo.createTask('Mow', projectId: project.id);
    await repo.trashProject(project.id);
    await repo.trash(task);
    await repo.restoreTask(task);

    final restored = await repo.task(task.id);
    expect(restored, isNotNull);
    expect(restored!.projectId, isNull);
    expect((await repo.tasks()).map((t) => t.id), contains(task.id));
  });

  test('purging a task calls the server and removes the row locally', () async {
    final task = await repo.createTask('Mow');
    await repo.trash(task);
    await repo.purgeTask(task);

    expect(requests, hasLength(1));
    expect(requests.single.method, 'DELETE');
    expect(requests.single.url.path, '/api/v1/tasks/${task.id}/purge');
    expect(await repo.task(task.id), isNull);
    expect(await repo.trashedTasks(), isEmpty);
  });

  test('emptying the Trash purges the deleted task and the deleted project with its tasks', () async {
    final project = await repo.createProject('Garden');
    final projectTask = await repo.createTask('Mow', projectId: project.id);
    final loose = await repo.createTask('Buy seeds');
    await repo.trashProject(project.id);
    await repo.trash(loose);

    await repo.emptyTrash();

    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/api/v1/trash/purge');
    expect((await repo.allProjects()).map((p) => p.id), isNot(contains(project.id)));
    expect(await repo.task(projectTask.id), isNull);
    expect(await repo.task(loose.id), isNull);
    expect(await repo.trashedTasks(), isEmpty);
    expect(await repo.trashedProjects(), isEmpty);
  });
}
