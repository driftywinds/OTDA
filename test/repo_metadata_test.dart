import 'package:flutter_test/flutter_test.dart';
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

  test('sections are read per project in board order and can be set on a task', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(
      db: db,
      client: ApiClient(baseUrl: Uri.parse('https://test.invalid'), jar: CookieJar()),
      clock: clock,
    );
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);

    await db.putField('section', 'later', 'name', 'Later', 1, 'a');
    await db.putField('section', 'later', 'project_id', 'p1', 1, 'a');
    await db.putField('section', 'later', 'position', 2, 1, 'a');
    await db.putField('section', 'now', 'name', 'Now', 2, 'a');
    await db.putField('section', 'now', 'project_id', 'p1', 2, 'a');
    await db.putField('section', 'now', 'position', 1, 2, 'a');
    await db.putField('section', 'other', 'name', 'Other project', 3, 'a');
    await db.putField('section', 'other', 'project_id', 'p2', 3, 'a');

    final sections = await repo.sections('p1');
    expect(sections.map((s) => s.name), ['Now', 'Later']);
    expect(await repo.sections('p2'), hasLength(1));

    final task = await repo.createTask('Mow', projectId: 'p1');
    await repo.setField('task', task.id, 'section_id', 'now');
    await repo.setField('task', task.id, 'deadline', '2026-11-30');
    await repo.setField('task', task.id, 'start', '2026-11-25');
    await repo.setField('task', task.id, 'estimate_minutes', 45);
    await repo.setField('task', task.id, 'energy', 'deep');
    final stored = (await repo.task(task.id))!;
    expect(stored.sectionId, 'now');
    expect(stored.deadline, '2026-11-30');
    expect(stored.startDate, '2026-11-25');
    expect(stored.estimateMinutes, 45);
    expect(stored.raw['energy'], 'deep');

    // A label made by name gets a real id and is reused by the same name.
    final id = await repo.ensureLabel('Errands');
    expect(id, isNotEmpty);
    expect(await repo.ensureLabel('errands'), id);
    expect((await repo.labels()).map((l) => l.name), contains('Errands'));

    await db.close();
  });
}
