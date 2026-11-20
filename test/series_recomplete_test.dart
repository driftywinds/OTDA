// Two bugs behind "the paper task vanished": a re-tick after an undo left the record
// tombstoned (so it never came back), and a second tick of the same occurrence rolled
// the series forward again, skipping a day.
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

String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var counter = 0;
  final now = DateTime.now();
  final today = iso(now);
  final tomorrow = iso(DateTime(now.year, now.month, now.day + 1));

  Future<(Repo, OtdaDb, HybridClock)> buildRepo() async {
    final path = p.join(Directory.systemTemp.path,
        'otda_series_fix_${DateTime.now().microsecondsSinceEpoch}_${counter++}.db');
    final db = await OtdaDb.open(path: path);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: ApiClient(baseUrl: Uri.parse('http://x'), jar: CookieJar()), clock: clock);
    return (Repo(db: db, clock: clock, engine: engine), db, clock);
  }

  Future<String> addDaily(OtdaDb db, HybridClock clock) async {
    const id = 'series-paper';
    final ts = await clock.next();
    for (final entry in {
      'title': 'Post e paper',
      'due': {'date': today, 'time': '09:00'},
      'recurrence': 'every day',
    }.entries) {
      await db.putField('task', id, entry.key, entry.value, ts, 'device');
    }
    return id;
  }

  test('undo then tick again brings the record back, not a tombstone', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addDaily(db, clock);

    await repo.setCompleted((await repo.tasks()).firstWhere((t) => t.id == id), true);
    final record = (await repo.tasks()).firstWhere((t) => t.raw['series_id'] == id);
    expect(record.isCompleted, isTrue);

    // Undo from History: the record goes away and the series comes back to today.
    await repo.setCompleted(record, false);
    expect((await repo.tasks()).where((t) => t.raw['series_id'] == id), isEmpty);
    final back = (await repo.tasks()).firstWhere((t) => t.id == id);
    expect(back.dueDate, today);

    // Ticking today again must bring the same record back to life.
    await repo.setCompleted(back, true);

    final again = (await repo.tasks()).firstWhere((t) => t.raw['series_id'] == id);
    expect(again.isDeleted, isFalse, reason: 'a re-ticked record must be live again');
    expect(again.isCompleted, isTrue);
  });

  test('ticking the same occurrence twice does not skip a day', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addDaily(db, clock);

    final series = (await repo.tasks()).firstWhere((t) => t.id == id);
    await repo.setCompleted(series, true);
    // The list may still hold the pre-roll row; a second tap must be harmless.
    await repo.setCompleted(series, true);

    final current = (await repo.tasks()).firstWhere((t) => t.id == id);
    expect(current.dueDate, tomorrow, reason: 'one tap, one day');
    final records = (await repo.tasks()).where((t) => t.raw['series_id'] == id).toList();
    expect(records, hasLength(1));
    expect(records.single.isDeleted, isFalse);
  });
}
