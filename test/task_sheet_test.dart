import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/ui/task_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('a finished occurrence shows the rule of its series', (tester) async {
    late Repo repo;
    late Task record;
    await tester.runAsync(() async {
      final db = await OtdaDb.open(path: inMemoryDatabasePath);
      final clock = await HybridClock.load(db);
      final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
      final engine = SyncEngine(db: db, client: client, clock: clock);
      await engine.open();
      repo = Repo(db: db, clock: clock, engine: engine);
      final ts = await clock.next();
      await db.putField('task', 'series', 'title', 'Plant water',
          ts, 'device');
      await db.putField('task', 'series', 'recurrence', 'every day until 2026-11-27',
          ts, 'device');
      await db.putField('task', 'series', 'due', {'date': '2026-11-25'}, ts, 'device');
      await db.putField('task', 'record', 'title', 'Plant water', ts, 'device');
      await db.putField('task', 'record', 'series_id', 'series', ts, 'device');
      await db.putField('task', 'record', 'occurrence_date', '2026-11-24', ts, 'device');
      await db.putField('task', 'record', 'completed_at', 1, ts, 'device');
      await db.putField('task', 'record', 'due', {'date': '2026-11-24', 'time': '09:00'}, ts, 'device');
      record = (await repo.tasks()).firstWhere((task) => task.id == 'record');
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TaskSheet(task: record, repo: repo, projects: const [])),
    ));
    // The sheet reads the series from the real SQLite replica, outside the fake
    // clock; give that future a turn before pumping the rebuilt row.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text('every day until 2026-11-27'), findsOneWidget);
  });
}
