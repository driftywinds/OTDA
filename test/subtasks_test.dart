import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
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

  setUp(() async {
    db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(
      db: db,
      client: ApiClient(baseUrl: Uri.parse('https://test.invalid'), jar: CookieJar()),
      clock: clock,
    );
    await engine.open();
    repo = Repo(db: db, clock: clock, engine: engine);
  });

  tearDown(() async => db.close());

  test('a subtask inherits the project, priority 4 and no due date, after its siblings', () async {
    final project = await repo.createProject('Garden');
    final parent = await repo.createTask('Mow', projectId: project.id);
    final first = await repo.createSubtask(parent, 'Edges');
    final second = await repo.createSubtask(parent, 'Clippings');

    expect(first.projectId, project.id);
    expect(first.priority, 4);
    expect(first.dueDate, isNull);
    expect(first.parentId, parent.id);
    expect(second.parentId, parent.id);
    expect((second.raw['position'] as num).toDouble(),
        greaterThan((first.raw['position'] as num).toDouble()));
    expect((await repo.childrenOf(parent.id)).map((t) => t.title), ['Edges', 'Clippings']);
  });

  test('progress counts direct live children only, and never stored', () async {
    final parent = await repo.createTask('Mow');
    final first = await repo.createSubtask(parent, 'Edges');
    final second = await repo.createSubtask(parent, 'Clippings');
    await repo.createSubtask(first, 'Grandchild');

    var progress = await repo.subtaskProgress(parent.id);
    expect(progress.done, 0);
    expect(progress.total, 2, reason: 'a grandchild counts toward its own parent');

    await repo.setCompleted(first, true);
    progress = await repo.subtaskProgress(parent.id);
    expect(progress.done, 1);

    await repo.trash(second);
    progress = await repo.subtaskProgress(parent.id);
    expect(progress.total, 1, reason: 'a deleted child counts nowhere');

    // Nothing about progress is written to the replica.
    final raw = (await repo.task(parent.id))!;
    expect(raw.raw.containsKey('progress'), isFalse);
    expect(raw.raw.containsKey('subtask_progress'), isFalse);
  });

  test('completing a plain task completes open descendants; reopening reopens only the parent', () async {
    final parent = await repo.createTask('Mow');
    final child = await repo.createSubtask(parent, 'Edges');
    final grandchild = await repo.createSubtask(child, 'Corner');
    final done = await repo.createSubtask(parent, 'Already done');
    await repo.setCompleted(done, true);

    await repo.setCompleted(parent, true);
    final tasks = {for (final t in await repo.tasks()) t.id: t};
    expect(tasks[parent.id]!.isCompleted, isTrue);
    expect(tasks[child.id]!.isCompleted, isTrue, reason: 'open descendants complete too');
    expect(tasks[grandchild.id]!.isCompleted, isTrue);
    expect(tasks[done.id]!.isCompleted, isTrue);

    await repo.setCompleted(tasks[parent.id]!, false);
    final reopened = {for (final t in await repo.tasks()) t.id: t};
    expect(reopened[parent.id]!.isCompleted, isFalse);
    expect(reopened[child.id]!.isCompleted, isTrue, reason: 'reopening never reopens descendants');
    expect(reopened[grandchild.id]!.isCompleted, isTrue);
  });

  test('a task moves under another parent, and not under itself, a descendant or another project', () async {
    final project = await repo.createProject('Garden');
    final other = await repo.createProject('House');
    final parent = await repo.createTask('Mow', projectId: project.id);
    final child = await repo.createSubtask(parent, 'Edges');
    final grandchild = await repo.createSubtask(child, 'Corner');
    final sibling = await repo.createSubtask(parent, 'Clippings');

    await repo.setParent(grandchild, sibling.id);
    expect((await repo.task(grandchild.id))!.parentId, sibling.id);

    expect(() => repo.setParent(parent, child.id), throwsA(isA<ApiException>()));
    expect(() => repo.setParent(parent, parent.id), throwsA(isA<ApiException>()));
    final foreign = await repo.createTask('Foreign', projectId: other.id);
    expect(() => repo.setParent(child, foreign.id), throwsA(isA<ApiException>()));

    // Promote to the top level.
    await repo.setParent(grandchild, null);
    expect((await repo.task(grandchild.id))!.parentId, isNull);
  });

  test('moving a parent to another project moves every descendant, one field write each', () async {
    final source = await repo.createProject('Garden');
    final target = await repo.createProject('House');
    final parent = await repo.createTask('Mow', projectId: source.id);
    final child = await repo.createSubtask(parent, 'Edges');
    final grandchild = await repo.createSubtask(child, 'Corner');
    await repo.setField('task', child.id, 'section_id', 'section-1');

    await repo.moveToProject(parent, target.id);
    for (final id in [parent.id, child.id, grandchild.id]) {
      expect((await repo.task(id))!.projectId, target.id);
    }
    expect((await repo.task(child.id))!.sectionId, isNull);
  });
}
