import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/stats.dart';

Task task(String id, Map<String, Object?> raw) => Task(id, {'id': id, ...raw});

int at(int year, int month, int day, [int hour = 12]) =>
    DateTime(year, month, day, hour).millisecondsSinceEpoch;

void main() {
  test('periods resolve to local calendar days, with Monday as the default week start', () {
    final week = periodFor(StatsPeriodKind.thisWeek, '2026-11-21');
    expect(week.start, '2026-11-16');
    expect(week.end, '2026-11-21');
    expect(week.days, hasLength(6));

    final last = periodFor(StatsPeriodKind.lastWeek, '2026-11-21');
    expect(last.start, '2026-11-09');
    expect(last.end, '2026-11-15');

    final month = periodFor(StatsPeriodKind.thisMonth, '2026-11-21');
    expect(month.start, '2026-11-01');
    final quarter = periodFor(StatsPeriodKind.thisQuarter, '2026-11-21');
    expect(quarter.start, '2026-10-01');
    final year = periodFor(StatsPeriodKind.thisYear, '2026-11-21');
    expect(year.start, '2026-01-01');

    final sunday = periodFor(StatsPeriodKind.thisWeek, '2026-11-21', weekStart: 7);
    expect(sunday.start, '2026-11-15');
  });

  test('completions count per day, project and label inside the period only', () {
    final tasks = [
      task('a', {
        'title': 'A',
        'completed_at': at(2026, 11, 17),
        'project_id': 'p1',
        'labels': ['l1', 'l2'],
      }),
      task('b', {
        'title': 'B',
        'completed_at': at(2026, 11, 17),
        'project_id': 'p1',
        'labels': ['l1'],
      }),
      task('c', {'title': 'C', 'completed_at': at(2026, 11, 19)}),
      task('d', {'title': 'D', 'completed_at': at(2026, 11, 10)}),
      task('e', {'title': 'E', 'completed_at': at(2026, 11, 18), 'deleted_at': 1}),
    ];
    final stats = computeStats(
      tasks: tasks,
      projects: [Project('p1', {'id': 'p1', 'name': 'Garden'})],
      labels: [Label('l1', {'id': 'l1', 'name': 'Errands'}), Label('l2', {'id': 'l2', 'name': 'Home'})],
      period: periodFor(StatsPeriodKind.thisWeek, '2026-11-21'),
      today: '2026-11-21',
    );

    expect(stats.completed, 3);
    expect(stats.perDay.firstWhere((d) => d.date == '2026-11-17').count, 2);
    expect(stats.perDay.firstWhere((d) => d.date == '2026-11-19').count, 1);
    expect(stats.perDay.firstWhere((d) => d.date == '2026-11-18').count, 0);
    expect(stats.perProject.map((p) => '${p.name}:${p.count}'), ['Garden:2', 'Inbox:1']);
    expect(stats.perLabel.map((l) => '${l.name}:${l.count}'), ['Errands:2', 'Home:1']);
  });

  test('a daily streak survives today or yesterday, and a skipped occurrence breaks it', () {
    final series = task('s1', {'title': 'Water', 'recurrence': 'every day', 'due': {'date': '2026-11-21'}});
    Task record(String date, {bool skipped = false}) => task('r-$date', {
          'title': 'Water',
          'series_id': 's1',
          'occurrence_date': date,
          'due': {'date': date},
          'completed_at': at(2026, 11, 21),
          'skipped': skipped,
        });

    final alive = seriesStreaks([
      series,
      record('2026-11-21'),
      record('2026-11-20'),
      record('2026-11-19'),
    ], '2026-11-21');
    expect(alive.single.count, 3);

    final brokenBySkip = seriesStreaks([
      series,
      record('2026-11-21'),
      record('2026-11-20', skipped: true),
      record('2026-11-19'),
    ], '2026-11-21');
    expect(brokenBySkip.single.count, 1);

    final stale = seriesStreaks([
      series,
      record('2026-11-18'),
      record('2026-11-17'),
    ], '2026-11-21');
    expect(stale, isEmpty, reason: 'three days without a completion breaks a daily streak');
  });

  test('a weekly streak uses the rule interval as its tolerated gap', () {
    final series = task('s2', {'title': 'Bins', 'recurrence': 'every week', 'due': {'date': '2026-11-21'}});
    Task record(String date) => task('r-$date', {
          'title': 'Bins',
          'series_id': 's2',
          'occurrence_date': date,
          'completed_at': at(2026, 11, 21),
        });

    final streak = seriesStreaks([
      series,
      record('2026-11-21'),
      record('2026-11-14'),
      record('2026-11-07'),
      record('2026-10-24'),
    ], '2026-11-21');
    expect(streak.single.count, 3, reason: 'a missed week (14 days) ends it');
  });
}
