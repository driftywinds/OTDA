import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/reminders/planner.dart';
import 'package:otda/src/ui/repeat_sheet.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('custom repeat rules', () {
    test('daily and interval rules use the grammar the server stores', () {
      expect(customRepeatRule(interval: 1, unit: 'day'), 'every day');
      expect(customRepeatRule(interval: 3, unit: 'day'), 'every 3 days');
      expect(customRepeatRule(interval: 2, unit: 'month'), 'every 2 months');
      expect(customRepeatRule(interval: 1, unit: 'year'), 'every year');
    });

    test('a weekly rule keeps the selected weekdays', () {
      expect(customRepeatRule(interval: 1, unit: 'week', weekdays: {3}), 'every wednesday');
      expect(
        customRepeatRule(interval: 2, unit: 'week', weekdays: {1, 3}),
        'every 2 weeks on monday, wednesday',
      );
    });

    test('completion-relative rules say so', () {
      expect(
        customRepeatRule(interval: 2, unit: 'week', afterCompletion: true),
        'every 2 weeks after completion',
      );
    });
  });

  group('repeat ends', () {
    test('adds and clears an end date', () {
      expect(repeatRuleEnding('every day', until: '2026-12-27'), 'every day until 2026-12-27');
      expect(repeatRuleEnding('every day until 2026-12-27'), 'every day');
    });

    test('adds and clears a count', () {
      expect(repeatRuleEnding('every weekday', count: 10), 'every weekday for 10 times');
      expect(repeatRuleEnding('every weekday for 10 times'), 'every weekday');
    });

    test('labels what is stored', () {
      expect(repeatEndLabel('every day', '2026-11-24'), 'Never');
      expect(repeatEndLabel('every day until 2026-12-27', '2026-11-24'), 'Ends Dec 27');
      expect(repeatEndLabel('every day for 10 times', '2026-11-24'), 'After 10 times');
    });
  });

  test('a task reminder offset is applied before the due time', () {
    final task = Task('a', {
      'id': 'a',
      'title': 'Call Sam',
      'due': {'date': '2026-11-24', 'time': '10:00'},
    });
    final plan = planReminders(
      [task],
      now: DateTime(2026, 11, 24, 8),
      zone: tz.getLocation('Etc/UTC'),
      offsets: const {'a': 30},
      defaultTime: '09:00',
    );
    expect(plan, hasLength(1));
    expect(plan.single.at, tz.TZDateTime(tz.getLocation('Etc/UTC'), 2026, 11, 24, 9, 30));
  });
}
