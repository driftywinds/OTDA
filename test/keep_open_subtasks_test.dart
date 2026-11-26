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

  test('keep leaves open children under a completed parent and hides them from lists', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);

    final parent = await repo.createTask('Trip');
    final child = await repo.createSubtask(parent, 'Book hotel');
    await repo.setUserPref('complete_subtasks', 'keep');

    await repo.setCompleted(parent, true);

    final rows = await db.entities('task');
    final parentRow = rows.firstWhere((row) => row['id'] == parent.id);
    final childRow = rows.firstWhere((row) => row['id'] == child.id);
    expect(parentRow['completed_at'], isNotNull);
    expect(childRow['completed_at'], isNull);
    expect((await repo.tasks()).map((task) => task.id), isNot(contains(child.id)));
    expect((await repo.childrenOf(parent.id)).map((task) => task.id), contains(child.id));

    await repo.setCompleted(parent, false);
    expect((await repo.tasks()).map((task) => task.id), contains(child.id));

    await repo.setUserPref('complete_subtasks', 'complete');
    await repo.setCompleted(parent, true);
    final completedChild = (await db.entities('task')).firstWhere((row) => row['id'] == child.id);
    expect(completedChild['completed_at'], isNotNull);

    await db.close();
  });
}
