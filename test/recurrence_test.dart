// A recurring task must not disappear from Upcoming just because its stored due
// date has passed: it is listed on its next occurrence instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/recurrence.dart';

Task task(Map<String, Object?> raw) => Task('t', {'id': 't', ...raw});

void main() {
  const today = '2026-11-18';

  test('a finished occurrence resolves its rule from the series', () {
    final series = Task('s', {
      'id': 's',
      'due': {'date': '2026-11-19'},
      'recurrence': 'every day until 2026-12-27',
    });
    final record = Task('r', {
      'id': 'r',
      'series_id': 's',
      'occurrence_date': '2026-11-18',
      'completed_at': 1,
    });

    expect(recurrenceFor(record, [series, record]), 'every day until 2026-12-27');
    expect(recurrenceLabelOf(recurrenceFor(record, [series, record])), 'every day until 2026-12-27');
    expect(recurrenceFor(record, [record]), '', reason: 'no series in the replica');
    expect(recurrenceFor(series, [series]), 'every day until 2026-12-27');
  });

  test('a plain task ahead uses its due date', () {
    expect(upcomingDay(task({'due': {'date': '2026-11-21'}}), [task({'due': {'date': '2026-11-21'}})], today), '2026-11-21');
  });

  test('a plain task in the past is not upcoming', () {
    expect(upcomingDay(task({'due': {'date': '2026-11-10'}}), [task({'due': {'date': '2026-11-10'}})], today), isNull);
  });

  test('a monthly task whose due has passed shows its next occurrence', () {
    final t = task({
      'due': {'date': '2026-10-01'},
      'recurrence': 'every month',
    });
    expect(upcomingDay(t, [t], today), '2026-12-01');
  });

  test('a daily task whose due has passed shows tomorrow', () {
    final t = task({
      'due': {'date': '2026-11-10'},
      'recurrence': 'every day',
    });
    expect(upcomingDay(t, [t], today), '2026-11-19');
  });

  test('a weekly task lands on the next weekday', () {
    final t = task({
      'due': {'date': '2026-11-13'}, // a Friday
      'recurrence': 'every friday',
    });
    expect(upcomingDay(t, [t], today), '2026-11-20');
  });

  test('a completed one-off is not upcoming', () {
    final t = task({
      'due': {'date': '2026-11-25'},
      'completed_at': 1795000000000,
    });
    expect(upcomingDay(t, [t], today), isNull);
  });

  test('a recurring task ticked off today stays upcoming, on its next day', () {
    final t = task({
      'due': {'date': today},
      'recurrence': 'every day',
      'completed_at': 1795000000000,
    });
    expect(upcomingDay(t, [t], today), '2026-11-19');
  });

  test('a completed daily task with an old due still shows tomorrow', () {
    final t = task({
      'due': {'date': '2026-11-10'},
      'recurrence': 'every day',
      'completed_at': 1795000000000,
    });
    expect(upcomingDay(t, [t], today), '2026-11-19');
  });

  test('a monthly task done today comes back next month, not never', () {
    final t = task({
      'due': {'date': today},
      'recurrence': 'every month',
      'completed_at': 1795000000000,
    });
    expect(upcomingDay(t, [t], today), '2026-12-18');
  });

  test('ticked off ahead of time: the next one is after the stored due', () {
    final t = task({
      'due': {'date': '2026-11-20'},
      'recurrence': 'every day',
      'completed_at': 1795000000000,
    });
    expect(upcomingDay(t, [t], today), '2026-11-21');
  });

  test('an open daily task due yesterday still shows tomorrow', () {
    final t = task({
      'due': {'date': '2026-11-17'},
      'recurrence': 'every day',
    });
    expect(upcomingDay(t, [t], today), '2026-11-19');
  });

  test('a completed series that has ended is not upcoming', () {
    final t = task({
      'due': {'date': '2026-11-01'},
      'recurrence': 'every day until 2026-11-05',
      'completed_at': 1795000000000,
    });
    expect(upcomingDay(t, [t], today), isNull);
  });

  test('a series that ended before today is not upcoming', () {
    final t = task({
      'due': {'date': '2026-11-01'},
      'recurrence': 'every month until 2026-11-05',
    });
    expect(upcomingDay(t, [t], today), isNull);
  });

  test('an undated task only appears when it repeats', () {
    expect(upcomingDay(task({'due': null}), [task({'due': null})], today), isNull);
    final recurring = task({'due': null, 'recurrence': 'every month'});
    expect(upcomingDay(recurring, [recurring], today), isNotNull);
  });

  test('the rule label is canonical where it parses', () {
    expect(recurrenceLabel(task({'recurrence': 'Every  2nd  Tuesday'})), 'every 2nd tuesday');
    expect(isRecurring(task({'recurrence': 'every day'})), isTrue);
    expect(isRecurring(task({})), isFalse);
  });
}
