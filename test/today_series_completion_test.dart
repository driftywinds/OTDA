// The reported bug: a daily task due at 09:00, ticked at 07:06 (before its time),
// vanished from Today instead of sitting struck through in "Done today". This pins
// what the completion writes and what the Today filter therefore sees.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/data/views.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String iso(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// The device's own day for a millisecond stamp, exactly as the Today list does it.
String dayOf(int millis) => iso(DateTime.fromMillisecondsSinceEpoch(millis));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var counter = 0;
  final today = iso(DateTime.now());
  final tomorrow = iso(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day + 1));

  Future<(Repo, OtdaDb, HybridClock)> buildRepo() async {
    final path = p.join(Directory.systemTemp.path,
        'otda_today_series_${DateTime.now().microsecondsSinceEpoch}_${counter++}.db');
    final db = await OtdaDb.open(path: path);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: ApiClient(baseUrl: Uri.parse('http://x'), jar: CookieJar()), clock: clock);
    return (Repo(db: db, clock: clock, engine: engine), db, clock);
  }

  Future<String> addSeries(OtdaDb db, HybridClock clock, String title) async {
    final id = 'series-$title';
    final ts = await clock.next();
    final fields = <String, Object?>{
      'title': title,
      'due': {'date': today, 'time': '09:00'},
      'recurrence': 'every day',
    };
    for (final entry in fields.entries) {
      await db.putField('task', id, entry.key, entry.value, ts, 'device');
    }
    return id;
  }

  test('ticking a daily task before its time leaves a record in Done today', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addSeries(db, clock, 'post e paper');

    final series = (await repo.tasks()).firstWhere((t) => t.id == id);
    await repo.setCompleted(series, true);

    final all = await repo.tasks();
    final records = all.where((t) => t.raw['series_id'] == id).toList();
    expect(records, hasLength(1), reason: 'a finished occurrence must be written as a record');

    final record = records.single;
    expect(record.dueDate, today, reason: 'the record stands for today, not tomorrow');
    expect(record.completedAt, isNotNull);
    expect(dayOf(record.completedAt!), today);

    // The two predicates the Today view uses to decide membership.
    bool finishedToday(Task t) =>
        t.completedAt != null && !t.isDeleted && dayOf(t.completedAt!) == today;
    final shown = all.where((t) => inToday(t.raw, today) || finishedToday(t)).toList();
    expect(shown.map((t) => t.id), contains(record.id),
        reason: 'Today must list the finished occurrence under Done today');

    // And the series itself has moved on, so it is not listed twice.
    final rolled = all.firstWhere((t) => t.id == id);
    expect(rolled.dueDate, tomorrow);
    expect(shown.where((t) => t.id == id), isEmpty);
  });

  test('a task due in two minutes and ticked still shows under Done today', () async {
    final (repo, db, clock) = await buildRepo();
    final id = 'quick-1';
    final ts = await clock.next();
    await db.putField('task', id, 'title', 'call back', ts, 'device');
    await db.putField('task', id, 'due', {'date': today, 'time': '23:59'}, ts, 'device');

    final task = (await repo.tasks()).firstWhere((t) => t.id == id);
    await repo.setCompleted(task, true);
    final done = (await repo.tasks()).firstWhere((t) => t.id == id);
    expect(done.completedAt, isNotNull);
    expect(dayOf(done.completedAt!), today);
  });
}
