// A tap on the widget becomes a pending op; the app applies it later. These pin what "apply" means,
// because the widget showed one thing and the replica did another:
//  - un-ticking the row you just ticked (series S) used to be dropped: S is never "completed", the
//    tick had really written a separate record R, so the tick survived and the widget snapped back;
//  - applying a tick twice ticked tomorrow's occurrence as well.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/reminders/service.dart';
import 'package:otda/src/widget/snapshot.dart';
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
  final yesterday = iso(DateTime(now.year, now.month, now.day - 1));
  final tomorrow = iso(DateTime(now.year, now.month, now.day + 1));

  Future<(Repo, OtdaDb, HybridClock)> buildRepo() async {
    final path = p.join(Directory.systemTemp.path,
        'otda_widget_ops_${DateTime.now().microsecondsSinceEpoch}_${counter++}.db');
    final db = await OtdaDb.open(path: path);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: ApiClient(baseUrl: Uri.parse('http://x'), jar: CookieJar()), clock: clock);
    return (Repo(db: db, clock: clock, engine: engine), db, clock);
  }

  Future<void> add(OtdaDb db, HybridClock clock, String id, Map<String, Object?> fields) async {
    final ts = await clock.next();
    for (final entry in fields.entries) {
      await db.putField('task', id, entry.key, entry.value, ts, 'device');
    }
  }

  Future<void> addDaily(OtdaDb db, HybridClock clock, String due) =>
      add(db, clock, 'S', {'title': 'Post e paper', 'due': {'date': due}, 'recurrence': 'every day'});

  Map<String, Object?> tick(String id, String day, {String? sid, String? occ, bool done = true, int at = 1}) =>
      {'id': id, 'day': day, 'done': done, 'at': at, 'sid': ?sid, 'occ': ?occ};

  Future<Task> series(Repo repo) async => (await repo.tasks()).firstWhere((t) => t.id == 'S');
  Future<List<Task>> records(Repo repo) async =>
      (await repo.tasks()).where((t) => t.raw['series_id'] == 'S').toList();

  test('tick a repeating task: a record for that day, the series moves on', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, today);

    expect(await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today)), isTrue);

    expect((await series(repo)).dueDate, tomorrow);
    final done = await records(repo);
    expect(done, hasLength(1));
    expect(done.single.isCompleted, isTrue);
    expect(done.single.raw['occurrence_date'], today);
  });

  test('the same tick applied twice does not tick tomorrow as well', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, today);

    await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today));
    expect(await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today)), isFalse);

    expect((await series(repo)).dueDate, tomorrow, reason: 'one tap, one day');
    expect(await records(repo), hasLength(1));
  });

  test('un-ticking the row you just ticked (before the app caught up) puts the series back', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, today);

    // Both taps were made on the optimistic row, whose id is the series'.
    await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today, at: 1));
    final changed = await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today, done: false, at: 2));

    expect(changed, isTrue, reason: 'this was the dropped op');
    expect((await series(repo)).dueDate, today);
    expect(await records(repo), isEmpty);
  });

  test('un-ticking the done record itself works too', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, today);
    await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today));
    final record = (await records(repo)).single;

    expect(await applyWidgetOp(repo, tick(record.id, today, sid: 'S', occ: today, done: false)), isTrue);

    expect((await series(repo)).dueDate, today);
    expect(await records(repo), isEmpty);
    // And an un-tick replayed is a no-op.
    expect(await applyWidgetOp(repo, tick(record.id, today, sid: 'S', occ: today, done: false)), isFalse);
  });

  test('tick, un-tick, tick again ends done, once', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, today);

    await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today, at: 1));
    await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today, done: false, at: 2));
    await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today, at: 3));

    expect((await series(repo)).dueDate, tomorrow);
    final done = await records(repo);
    expect(done, hasLength(1));
    expect(done.single.isDeleted, isFalse);
  });

  test('an OVERDUE daily task: tick, then un-tick, returns to the overdue day', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, yesterday);

    await applyWidgetOp(repo, tick('S', yesterday, sid: 'S', occ: yesterday, at: 1));
    final record = (await records(repo)).single;
    expect(record.raw['occurrence_date'], yesterday);
    expect((await series(repo)).dueDate, isNot(yesterday));

    // The tap on the done row carries the record's id and the same occurrence.
    await applyWidgetOp(repo, tick(record.id, yesterday, sid: 'S', occ: yesterday, done: false, at: 2));

    expect((await series(repo)).dueDate, yesterday);
    expect(await records(repo), isEmpty);
  });

  test('a tick for a day the series has already left is ignored (it was applied already)', () async {
    final (repo, db, clock) = await buildRepo();
    await addDaily(db, clock, tomorrow);

    expect(await applyWidgetOp(repo, tick('S', today, sid: 'S', occ: today)), isFalse);

    expect((await series(repo)).dueDate, tomorrow);
    expect(await records(repo), isEmpty);
  });

  test('a plain task: tick, un-tick, and replays change nothing the second time', () async {
    final (repo, db, clock) = await buildRepo();
    await add(db, clock, 'P', {'title': 'File receipts', 'due': {'date': today}});

    expect(await applyWidgetOp(repo, tick('P', today)), isTrue);
    expect(await applyWidgetOp(repo, tick('P', today)), isFalse);
    expect((await repo.tasks()).firstWhere((t) => t.id == 'P').isCompleted, isTrue);

    expect(await applyWidgetOp(repo, tick('P', today, done: false)), isTrue);
    expect(await applyWidgetOp(repo, tick('P', today, done: false)), isFalse);
    expect((await repo.tasks()).firstWhere((t) => t.id == 'P').isCompleted, isFalse);
  });

  group('the snapshot the widget overlays taps on', () {
    Task task(String id, Map<String, Object?> raw) => Task(id, {'id': id, ...raw});

    test('rows carry the series and occurrence, and the snapshot its ack', () {
      final doneAt = DateTime.now().millisecondsSinceEpoch;
      final snapshot = buildWidgetSnapshot([
        task('S', {'title': 'Paper', 'due': {'date': tomorrow}, 'recurrence': 'every day'}),
        task('R', {
          'title': 'Paper',
          'series_id': 'S',
          'occurrence_date': today,
          'due': {'date': today},
          'completed_at': doneAt,
        }),
        task('P', {'title': 'Plain', 'due': {'date': today}}),
      ], const [], today: today, ack: 42);

      expect(snapshot['ack'], 42);
      final rows = (snapshot['rows'] as List).cast<Map>().where((r) => r['t'] == 'task').toList();
      final record = rows.firstWhere((r) => r['id'] == 'R');
      final open = rows.firstWhere((r) => r['id'] == 'S');
      final plain = rows.firstWhere((r) => r['id'] == 'P');
      expect([record['sid'], record['occ']], ['S', today]);
      expect([open['sid'], open['occ']], ['S', tomorrow]);
      expect(plain.containsKey('sid'), isFalse);
    });

    test('one build for every project equals a build per project', () {
      final tasks = [
        task('a', {'title': 'A', 'due': {'date': today}, 'project_id': 'p1'}),
        task('b', {'title': 'B', 'due': {'date': yesterday}, 'project_id': 'p2'}),
        task('s', {'title': 'S', 'due': {'date': today}, 'recurrence': 'every day', 'project_id': 'p1'}),
      ];
      final projects = [Project('p1', {'id': 'p1', 'name': 'One'}), Project('p2', {'id': 'p2', 'name': 'Two'})];
      final many = buildWidgetSnapshots(tasks, projects, projectIds: ['all', 'p1', 'p2'], today: today, ack: 7);
      for (final id in ['all', 'p1', 'p2']) {
        final single = buildWidgetSnapshot(tasks, projects, projectId: id == 'all' ? null : id, today: today, ack: 7);
        expect(many[id]!['rows'], single['rows'], reason: id);
        expect(many[id]!['more'], single['more'], reason: id);
        expect(many[id]!['ack'], 7);
      }
    });
  });
}
