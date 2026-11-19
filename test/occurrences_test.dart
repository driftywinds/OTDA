// The calendar lists a repeating task on every day it occurs, so a daily task
// shows on every day of the month rather than only on its stored due date.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/occurrences.dart';

Task task(String id, Map<String, Object?> raw) => Task(id, {'id': id, ...raw});

List<String> daysOf(List<(String, Task)> list) => [for (final e in list) e.$1];

void main() {
  test('a daily task appears on every day of the range', () {
    final occurrences = occurrencesBetween(
      [task('daily', {'due': {'date': '2026-11-10'}, 'recurrence': 'every day'})],
      '2026-11-18',
      '2026-11-21',
    );
    expect(daysOf(occurrences), ['2026-11-18', '2026-11-19', '2026-11-20', '2026-11-21']);
    expect(occurrences.every((e) => e.$2.id == 'daily'), isTrue);
  });

  test('a monthly task appears once in a month', () {
    final occurrences = occurrencesBetween(
      [task('rent', {'due': {'date': '2026-10-01'}, 'recurrence': 'every month'})],
      '2026-11-01',
      '2026-11-30',
    );
    expect(daysOf(occurrences), ['2026-11-01']);
  });

  test('a weekly task appears on its weekday', () {
    final occurrences = occurrencesBetween(
      [task('week', {'due': {'date': '2026-11-13'}, 'recurrence': 'every friday'})],
      '2026-11-16',
      '2026-12-04',
    );
    expect(daysOf(occurrences), ['2026-11-20', '2026-11-27', '2026-12-04']);
  });

  test('a plain task appears once, and only inside the range', () {
    final tasks = [
      task('in', {'due': {'date': '2026-11-20'}}),
      task('before', {'due': {'date': '2026-11-01'}}),
      task('after', {'due': {'date': '2026-12-20'}}),
    ];
    final occurrences = occurrencesBetween(tasks, '2026-11-18', '2026-11-30');
    expect(daysOf(occurrences), ['2026-11-20']);
  });

  test('an ended series stops at its until date', () {
    final occurrences = occurrencesBetween(
      [
        task('old', {
          'due': {'date': '2026-11-01'},
          'recurrence': 'every day until 2026-11-03',
        }),
      ],
      '2026-11-01',
      '2026-11-30',
    );
    expect(daysOf(occurrences), ['2026-11-01', '2026-11-02', '2026-11-03']);
  });

  test('a deleted task is not expanded', () {
    final occurrences = occurrencesBetween(
      [
        task('gone', {
          'due': {'date': '2026-11-18'},
          'recurrence': 'every day',
          'deleted_at': 1795000000000,
        }),
      ],
      '2026-11-18',
      '2026-11-20',
    );
    expect(occurrences, isEmpty);
  });

  test('a rule that cannot be read falls back to its due date', () {
    final occurrences = occurrencesBetween(
      [task('odd', {'due': {'date': '2026-11-19'}, 'recurrence': 'every blue moon'})],
      '2026-11-18',
      '2026-11-20',
    );
    expect(daysOf(occurrences), ['2026-11-19']);
  });

  test('the window helpers land on month edges', () {
    expect(firstOfMonth('2026-11-18', 0), '2026-11-01');
    expect(firstOfMonth('2026-11-18', -3), '2026-08-01');
    expect(lastOfMonth('2026-11-18', 0), '2026-11-30');
    expect(lastOfMonth('2026-12-05', 1), '2027-01-31');
  });
}
