// The planner is pure: same tasks and clock, same plan. These pin the rules the
// blueprint calls out - times in the local zone, no-time defaults, done and
// skipped occurrences left out, the cap, and an occurrence already past.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/reminders/planner.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Task task(String id, Map<String, Object?> raw) => Task(id, {'id': id, ...raw});

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.UTC);
  });

  final now = tz.TZDateTime(tz.UTC, 2026, 11, 19, 8);

  test('a task with a time fires at that wall-clock time', () {
    final plan = planReminders(
      [task('a', {'title': 'Standup', 'due': {'date': '2026-11-19', 'time': '09:30'}})],
      now: now,
      zone: tz.local,
    );
    expect(plan, hasLength(1));
    expect(plan.single.at.hour, 9);
    expect(plan.single.at.minute, 30);
    expect(plan.single.title, 'Standup');
    expect(plan.single.payload, 'a|2026-11-19');
  });

  test('a dated task without a time uses the default', () {
    final plan = planReminders(
      [task('b', {'title': 'Pay rent', 'due': {'date': '2026-11-20'}})],
      now: now,
      zone: tz.local,
      defaultTime: '08:15',
    );
    expect(plan.single.at.hour, 8);
    expect(plan.single.at.minute, 15);
  });

  test('a past occurrence is not armed', () {
    final plan = planReminders(
      [task('c', {'title': 'Early', 'due': {'date': '2026-11-19', 'time': '07:00'}})],
      now: now,
      zone: tz.local,
    );
    expect(plan, isEmpty);
  });

  test('a daily series yields one reminder per day in the window', () {
    final plan = planReminders(
      [task('d', {'title': 'Post e paper', 'due': {'date': '2026-11-19', 'time': '09:00'}, 'recurrence': 'every day'})],
      now: now,
      zone: tz.local,
      window: const Duration(days: 2),
    );
    expect(plan.map((p) => p.day), ['2026-11-19', '2026-11-20', '2026-11-21']);
  });

  test('done tasks and occurrence records are left out', () {
    final plan = planReminders([
      task('e', {'title': 'Done', 'due': {'date': '2026-11-20'}, 'completed_at': 1}),
      task('f', {'title': 'Record', 'due': {'date': '2026-11-20'}, 'series_id': 'e', 'occurrence_date': '2026-11-19'}),
    ], now: now, zone: tz.local);
    expect(plan, isEmpty);
  });

  test('the plan is capped and sorted', () {
    final tasks = [
      for (var i = 0; i < 60; i++)
        task('t$i', {'title': 'T$i', 'due': {'date': '2026-11-20', 'time': '${(i % 20).toString().padLeft(2, '0')}:00'}}),
    ];
    final plan = planReminders(tasks, now: now, zone: tz.local, maxCount: 5);
    expect(plan, hasLength(5));
    for (var i = 1; i < plan.length; i++) {
      expect(plan[i].at.isBefore(plan[i - 1].at), isFalse);
    }
  });

  test('a snooze replaces the occurrence time, and the id stays the same', () {
    final base = planReminders(
      [task('g', {'title': 'Snooze me', 'due': {'date': '2026-11-19', 'time': '09:00'}})],
      now: now,
      zone: tz.local,
    ).single;
    final snoozed = planReminders(
      [task('g', {'title': 'Snooze me', 'due': {'date': '2026-11-19', 'time': '09:00'}})],
      now: now,
      zone: tz.local,
      snoozedUntil: {'g|2026-11-19': tz.TZDateTime(tz.local, 2026, 11, 19, 9, 10)},
    ).single;
    expect(snoozed.id, base.id);
    expect(snoozed.at.minute, 10);
  });

  test('the id is stable across replans', () {
    expect(reminderId('x', '2026-11-19'), reminderId('x', '2026-11-19'));
    expect(reminderId('x', '2026-11-19'), isNot(reminderId('x', '2026-11-20')));
  });
}
