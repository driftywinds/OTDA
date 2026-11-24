import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/ui/format.dart';

void main() {
  const today = '2026-11-18'; // a Wednesday

  test('friendlyDate says today, tomorrow and yesterday', () {
    expect(friendlyDate('2026-11-18', today), 'Today');
    expect(friendlyDate('2026-11-19', today), 'Tomorrow');
    expect(friendlyDate('2026-11-17', today), 'Yesterday');
  });

  test('friendlyDate uses a weekday inside the coming week, a date beyond', () {
    expect(friendlyDate('2026-11-20', today), 'Fri');
    expect(friendlyDate('2026-12-05', today), 'Dec 5');
    expect(friendlyDate('2027-01-02', today), 'Jan 2, 2027');
  });

  test('friendlyDate hands back what it cannot parse', () {
    expect(friendlyDate('soon', today), 'soon');
  });

  test('daysBetween is negative for the past', () {
    expect(daysBetween(today, '2026-11-15'), -3);
    expect(daysBetween(today, 'nope'), isNull);
  });

  test('serverVersionLabel has exactly one leading v', () {
    expect(serverVersionLabel('v1.7.0'), 'v1.7.0');
    expect(serverVersionLabel('1.7.0'), 'v1.7.0');
    expect(serverVersionLabel('  v1.7.0  '), 'v1.7.0');
    expect(serverVersionLabel(''), '?');
    expect(serverVersionLabel(null), '?');
  });

  test('durationLabel', () {
    expect(durationLabel(45), '45m');
    expect(durationLabel(120), '2h');
    expect(durationLabel(90), '1h 30m');
  });
}
