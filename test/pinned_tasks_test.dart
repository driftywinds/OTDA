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

  test('pins are local to the replica and clear when a task is completed', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);

    final task = await repo.createTask('Pinned task');
    await repo.setPinned(task.id, true);
    expect(await repo.pinnedTaskIds(), {task.id});
    expect(await db.meta('ui.pinned_tasks'), contains(task.id));

    await repo.setCompleted(task, true);
    expect(await repo.pinnedTaskIds(), isEmpty);

    await db.close();
  });
}
