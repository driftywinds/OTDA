import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd/quickadd.dart';
import 'package:otda/src/quickadd/vocab/types.dart';

void main() {
  QuickAddResult parse(String line, {DayMonthOrder order = DayMonthOrder.md}) => parseQuickAdd(
        line,
        today: '2026-01-01',
        now: '10:00',
        language: 'en',
        dayMonthOrder: order,
      );

  group('month-first dashed ranges', () {
    test('a bare dashed pair stays a quantity range', () {
      final result = parse('Buy 3-4 tomatoes');
      expect(result.title, 'Buy 3-4 tomatoes');
      expect(result.fields.containsKey('due'), isFalse);
    });

    test('a dashed day and month that cannot be a range stays text', () {
      final result = parse('Party 25-12');
      expect(result.title, 'Party 25-12');
      expect(result.fields.containsKey('due'), isFalse);
    });

    test('a slash is still a date', () {
      final result = parse('Buy 3/4');
      expect(result.title, 'Buy');
      expect(result.fields['due'], {'date': '2026-03-04'});
    });

    test('a year makes a dashed date unambiguous', () {
      final result = parse('Buy 3-4-2027');
      expect(result.title, 'Buy');
      expect(result.fields['due'], {'date': '2027-03-04'});
    });

    test('on and by introduce a dashed date', () {
      final on = parse('Buy on 25-12');
      expect(on.fields['due'], {'date': '2026-12-25'});
      final by = parse('Buy by 4-15');
      expect(by.fields['deadline'], '2026-04-15');
    });

    test('day-first locales still read 3-4 as a date', () {
      final result = parse('Buy 3-4', order: DayMonthOrder.dm);
      expect(result.title, 'Buy');
      expect(result.fields['due'], {'date': '2026-04-03'});
    });
  });
}
