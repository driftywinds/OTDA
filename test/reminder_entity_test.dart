import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the repeat sheet stores a relative reminder as a synced reminder row', () async {
    final path = p.join(Directory.systemTemp.path,
        'otda_reminder_${DateTime.now().microsecondsSinceEpoch}.db');
    final db = await OtdaDb.open(path: path);
    final clock = await HybridClock.load(db);
    final repo = Repo(
      db: db,
      clock: clock,
      engine: SyncEngine(
        db: db,
        client: ApiClient(baseUrl: Uri.parse('http://x'), jar: CookieJar()),
        clock: clock,
      ),
    );
    final ts = await clock.next();
    await db.putField('task', 't', 'title', 'Call Sam', ts, 'device');

    expect(await repo.taskReminderOffset('t'), isNull);
    final task = (await repo.tasks()).single;
    await repo.setTaskReminderOffset(task, 30);

    expect(await repo.taskReminderOffset('t'), 30);
    final row = (await db.entities('reminder')).single;
    expect(row['kind'], 'relative');
    expect(row['offset_minutes'], -30, reason: 'OpenTodo counts negative minutes before the due time');

    await repo.setTaskReminderOffset(task, 10);
    expect(await repo.taskReminderOffset('t'), 10);
    expect(await db.entities('reminder'), hasLength(1), reason: 'one reminder is updated, not duplicated');

    await repo.setTaskReminderOffset(task, null);
    expect(await repo.taskReminderOffset('t'), isNull);
  });
}
