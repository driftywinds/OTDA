// The drawer a tap on a reminder opens: two big buttons at the bottom, and the same snooze rules as the
// notification's own buttons (both go through snoozeTarget / applyReminderAction).
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/reminder_sheet_app.dart';
import 'package:otda/src/reminders/service.dart';

Task task() => Task('t1', {
      'id': 't1',
      'title': 'Plant water',
      'due': {'date': '2026-11-27', 'time': '09:00'},
    });

void main() {
  group('snoozeTarget', () {
    final now = DateTime(2026, 11, 27, 23, 55);

    test('10 minutes and an hour count from now, across midnight', () {
      expect(snoozeTarget('snooze_10', now, '09:00'), DateTime(2026, 11, 28, 0, 5));
      expect(snoozeTarget('snooze_60', now, '09:00'), DateTime(2026, 11, 28, 0, 55));
    });

    test('tomorrow lands on the reminder time, and a month end rolls over', () {
      expect(snoozeTarget('snooze_tomorrow', DateTime(2026, 11, 30, 18), '08:30'), DateTime(2026, 12, 1, 8, 30));
    });

    test('a broken time falls back to 9:00; an unknown action is no snooze', () {
      expect(snoozeTarget('snooze_tomorrow', now, 'xx'), DateTime(2026, 11, 28, 9));
      expect(snoozeTarget('complete', now, '09:00'), isNull);
      expect(snoozeTarget('nope', now, '09:00'), isNull);
    });
  });

  group('ReminderSheet', () {
    Future<void> open(WidgetTester tester, void Function(String?) onResult) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => onResult(await showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ReminderSheet(task: task(), day: '2026-11-27', projectName: 'Inbox'),
                )),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the task, its project and both buttons', (tester) async {
      await open(tester, (_) {});
      expect(find.text('Plant water'), findsOneWidget);
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Snooze'), findsOneWidget);
      expect(find.text('Complete'), findsOneWidget);
    });

    testWidgets('Complete closes with "complete"', (tester) async {
      String? result;
      await open(tester, (r) => result = r);
      await tester.tap(find.text('Complete'));
      await tester.pumpAndSettle();
      expect(result, 'complete');
    });

    testWidgets('Snooze offers durations, and a choice closes with its action', (tester) async {
      String? result;
      await open(tester, (r) => result = r);
      await tester.tap(find.text('Snooze'));
      await tester.pumpAndSettle();
      expect(find.text('Complete'), findsNothing);
      await tester.tap(find.text('1 hour'));
      await tester.pumpAndSettle();
      expect(result, 'snooze_60');
    });

    testWidgets('Back returns to the two buttons; Close dismisses with nothing', (tester) async {
      String? result = 'unset';
      await open(tester, (r) => result = r);
      await tester.tap(find.text('Snooze'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Complete'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });
}
