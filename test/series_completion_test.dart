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
import 'package:otda/src/data/recurrence.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/series.dart';
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

  test('a skipped date is stepped over by the projection', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'skip-1', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });

    // Today done, tomorrow skipped by another device (or this one).
    await repo.setCompleted(await taskById(repo, id), true);
    await repo.deleteSeries(await taskById(repo, id), SeriesScope.occurrence);

    final series = await taskById(repo, id);
    final all = await repo.tasks();
    expect(upcomingDay(series, all, today), shift(today, 2),
        reason: 'the skipped day is not offered again');
    expect(recordsOf(id, all).map((r) => r.date), containsAll([today, tomorrow]));
  });

  test('un-ticking an occurrence record puts the series back, not a second task', () async {
    final (repo, db, clock) = await buildRepo();
    final id = await addTask(db, clock, 'undo-1', {
      'title': 'Post e paper',
      'due': {'date': tomorrow},
      'recurrence': 'every day',
    });

    // Ticked from Upcoming: the series rolls to the day after tomorrow.
    await repo.setCompleted(await taskById(repo, id), true);
    expect((await taskById(repo, id)).dueDate, shift(today, 2));

    // Un-ticked again: History shows the occurrence record, not the series.
    final record = (await repo.tasks()).firstWhere((t) => t.raw['series_id'] == id);
    await repo.setCompleted(record, false);

    final all = await repo.tasks();
    final series = all.firstWhere((t) => t.id == id);
    expect(series.dueDate, tomorrow);
    // The record is gone, so Upcoming has exactly one row for this task.
    expect(all.where((t) => t.raw['series_id'] == id), isEmpty);
    final shown = all.where((t) => upcomingDay(t, all, today) != null).toList();
    expect(shown, hasLength(1));
    expect(upcomingDay(series, all, today), tomorrow);
  });

  group('completing the occurrence a reminder was for', () {
    test('a newer occurrence is recorded on its own, and the series stays on today', () async {
      final (repo, db, clock) = await buildRepo();
      final id = await addTask(db, clock, 'series-r1', {
        'title': 'Water plants',
        'due': {'date': today},
        'recurrence': 'every day',
      });

      expect(await repo.completeOccurrence(await taskById(repo, id), tomorrow), isTrue);

      final series = await taskById(repo, id);
      expect(series.dueDate, today, reason: 'today is still open');
      expect(series.isCompleted, isFalse);
      final records = (await repo.tasks()).where((t) => t.raw['series_id'] == id).toList();
      expect(records.single.raw['occurrence_date'], tomorrow);
      expect(records.single.isCompleted, isTrue);

      // Ticking again changes nothing.
      expect(await repo.completeOccurrence(await taskById(repo, id), tomorrow), isFalse);
      expect((await repo.tasks()).where((t) => t.raw['series_id'] == id), hasLength(1));

      // Today's own tick then steps over the day that is already done.
      expect(await repo.completeOccurrence(await taskById(repo, id), today), isTrue);
      expect((await taskById(repo, id)).dueDate, shift(today, 2));
    });

    test('an older occurrence is recorded without moving the series', () async {
      final (repo, db, clock) = await buildRepo();
      final yesterday = shift(today, -1);
      final id = await addTask(db, clock, 'series-r2', {
        'title': 'Water plants',
        'due': {'date': today},
        'recurrence': 'every day',
      });

      expect(await repo.completeOccurrence(await taskById(repo, id), yesterday), isTrue);

      expect((await taskById(repo, id)).dueDate, today, reason: "today's occurrence is untouched");
      final record = (await repo.tasks()).singleWhere((t) => t.raw['series_id'] == id);
      expect(record.raw['occurrence_date'], yesterday);
      expect(record.isCompleted, isTrue);
      expect(await repo.completeOccurrence(await taskById(repo, id), yesterday), isFalse);
    });

    test('the current occurrence rolls the series on, as an ordinary tick does', () async {
      final (repo, db, clock) = await buildRepo();
      final id = await addTask(db, clock, 'series-r3', {
        'title': 'Water plants',
        'due': {'date': today},
        'recurrence': 'every day',
      });
      expect(await repo.completeOccurrence(await taskById(repo, id), today), isTrue);
      expect((await taskById(repo, id)).dueDate, tomorrow);
    });
  });
}
