import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Map<String, dynamic> op(String field, Object? value, int ts, String device) => {
        'entity': 'task',
        'entityId': 't1',
        'field': field,
        'value': value,
        'ts': ts,
        'device': device,
      };

  test('the page batch keeps the same (ts, device) winner rule as a live write', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);

    final written = await db.applyOps([
      op('title', 'first', 100, 'a'),
      op('title', 'second', 200, 'a'),
      op('title', 'same clock, larger device', 200, 'b'),
      op('title', 'older, must lose', 150, 'z'),
    ]);
    expect(written, 3);
    expect((await db.entity('task', 't1'))!['title'], 'same clock, larger device');

    // A page that arrives out of order still converges on the highest clock.
    await db.applyOps([op('title', 'newer', 400, 'a'), op('title', 'older', 300, 'z')]);
    expect((await db.entity('task', 't1'))!['title'], 'newer');

    // The same key from an earlier page cannot win.
    final stale = await db.applyOps([op('title', 'stale', 250, 'z')]);
    expect(stale, 0);
    expect((await db.entity('task', 't1'))!['title'], 'newer');

    // Fields in one page do not collide with each other.
    await db.applyOps([op('priority', 2, 500, 'a'), op('title', 'final', 500, 'a')]);
    final row = (await db.entity('task', 't1'))!;
    expect(row['priority'], 2);
    expect(row['title'], 'final');

    await db.close();
  });

  test('a page larger than one SQL parameter chunk reads every entity', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final ops = [
      for (var i = 0; i < 900; i++)
        {
          'entity': 'task',
          'entityId': 't$i',
          'field': 'title',
          'value': 'Task $i',
          'ts': 100,
          'device': 'a',
        },
    ];
    expect(await db.applyOps(ops), 900);
    expect((await db.entity('task', 't899'))!['title'], 'Task 899');
    await db.close();
  });
}
