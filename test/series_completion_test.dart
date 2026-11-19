// Completing a repeating task finishes one occurrence, not the series: the series
// must roll to its next date and keep coming back. The web client writes an
// occurrence record (series_id + occurrence_date) and moves the series; the app
// used to write completed_at on the series, which ended it for good.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String iso(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

String shift(String day, int days) {
  final d = DateTime.parse(day);
  return iso(DateTime(d.year, d.month, d.day + days));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var counter = 0;
  final today = iso(DateTime.now());
  final tomorrow = shift(today, 1);

  Future<(Repo, OtdaDb, HybridClock)> buildRepo() async {
    final path = p.join(Directory.systemTemp.path, 'otda_series_${DateTime.now().microsecondsSinceEpoch}_${counter++}.db');
    final db = await OtdaDb.open(path: path);
    final clock = await HybridClock.load(db);
    final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    return (Repo(db: db, clock: clock, engine: engine), db, clock);
  }

  Future<String> addTask(OtdaDb db, HybridClock clock, String id, Map<String, Object?> fields) async {
    for (final entry in fields.entries) {
      await db.putField('task', id, entry.key, entry.value, await clock.next(), 'test');
    }
    return id;
  }

  Future<Task> taskById(Repo repo, String id) async =>
      (await repo.tasks()).firstWhere((task) => task.id == id);

  test('a daily task rolls to tomorrow and leaves a finished record', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'series-1', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });

    await repo.setCompleted(await taskById(repo, id), true);

    final series = await taskById(repo, id);
    expect(series.isCompleted, isFalse, reason: 'the series is not finished');
    expect(series.dueDate, tomorrow, reason: 'it comes round tomorrow');

    final records = (await repo.tasks()).where((task) => task.raw['series_id'] == id).toList();
    expect(records, hasLength(1));
    expect(records.single.raw['occurrence_date'], today);
    expect(records.single.isCompleted, isTrue);
    expect(records.single.raw['recurrence'], isNull);
  });

  test('undoing the tick puts the series back on today and removes the record', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'series-2', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });

    await repo.setCompleted(await taskById(repo, id), true);
    await repo.setCompleted(await taskById(repo, id), false);

    final series = await taskById(repo, id);
    expect(series.dueDate, today);
    final live = (await repo.tasks())
        .where((task) => task.raw['series_id'] == id && !task.isDeleted)
        .toList();
    expect(live, isEmpty);
  });

  test('a one-off still completes and keeps its date', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'plain-1', {
      'title': 'Pay rent',
      'due': {'date': today},
    });

    await repo.setCompleted(await taskById(repo, id), true);

    final task = await taskById(repo, id);
    expect(task.isCompleted, isTrue);
    expect(task.dueDate, today);
  });

  test('a series past its until date completes instead of rolling', () async {
    final (repo, db, clock) = await buildRepo();
    final ended = shift(today, -2);
    final id = await addTask(db, clock, 'series-3', {
      'title': 'Old report',
      'due': {'date': ended},
      'recurrence': 'every day until $ended',
    });

    await repo.setCompleted(await taskById(repo, id), true);

    final task = await taskById(repo, id);
    expect(task.isCompleted, isTrue);
    expect((await repo.tasks()).where((t) => t.raw['series_id'] == id), isEmpty);
  });

  test('a monthly task rolls a month, not a day', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'series-4', {
      'title': 'Rent',
      'due': {'date': today},
      'recurrence': 'every month',
    });

    await repo.setCompleted(await taskById(repo, id), true);

    final series = await taskById(repo, id);
    final due = DateTime.parse(series.dueDate!);
    final expected = DateTime(DateTime.parse(today).year, DateTime.parse(today).month + 1, DateTime.parse(today).day);
    expect(iso(due), iso(expected));
  });

  test('deleting this occurrence skips it and keeps the series going', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'del-1', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });

    await repo.deleteSeries(await taskById(repo, id), SeriesScope.occurrence);

    final series = await taskById(repo, id);
    expect(series.isCompleted, isFalse);
    expect(series.dueDate, tomorrow);
    final record = (await repo.tasks()).firstWhere((task) => task.raw['series_id'] == id);
    expect(record.raw['skipped'], isTrue);
    expect(record.isCompleted, isTrue);
  });

  test('deleting this and future ends the series and keeps the past', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'del-2', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });
    await repo.setCompleted(await taskById(repo, id), true); // one past occurrence
    final rolled = await taskById(repo, id);

    await repo.deleteSeries(rolled, SeriesScope.future);

    final series = await taskById(repo, id);
    expect(series.isCompleted, isTrue, reason: 'nothing of it remains');
    expect(series.raw['recurrence'], contains('until'));
    // The occurrence finished before the truncation is still history.
    expect((await repo.tasks()).where((t) => t.raw['series_id'] == id && !t.isDeleted), hasLength(1));
  });

  test('deleting all occurrences tombstones the series and its records', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'del-3', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });
    await repo.setCompleted(await taskById(repo, id), true);

    await repo.deleteSeries(await taskById(repo, id), SeriesScope.all);

    final rows = await db.entities('task', includeDeleted: true);
    expect(rows.firstWhere((row) => row['id'] == id)['deleted_at'], isNotNull);
    expect(rows.where((row) => row['series_id'] == id && row['deleted_at'] == null), isEmpty);
  });
}
