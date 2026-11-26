// The month grid is pure UI: dates, task dots and taps, no network, no timers.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/ui/calendar_month.dart';

const months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

Task task(String id, String due, {bool done = false}) => Task(id, {
      'due': {'date': due},
      if (done) 'completed_at': '2026-03-01T00:00:00Z',
    });

ValueKey<String> dayKey(DateTime day) => ValueKey('day-${day.year}-${day.month}-${day.day}');

Finder dotsOn(DateTime day) => find.descendant(
      of: find.byKey(dayKey(day)),
      matching: find.byIcon(Icons.circle),
    );

Widget app(
  List<Task> tasks, {
  DateTime? initialMonth,
  void Function(DateTime)? onDaySelected,
}) =>
    MaterialApp(
      home: Scaffold(
        body: MonthCalendar(
          tasks: tasks,
          initialMonth: initialMonth,
          onDaySelected: onDaySelected ?? (_) {},
        ),
      ),
    );

void main() {
  testWidgets('shows the current month and marks today', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(app(const []));

    expect(find.text('${months[now.month - 1]} ${now.year}'), findsOneWidget);
    final today = find.byKey(dayKey(now));
    expect(today, findsOneWidget);
    expect(find.descendant(of: today, matching: find.byKey(const Key('calendar-today'))), findsOneWidget);
    expect(find.descendant(of: today, matching: find.text('${now.day}')), findsOneWidget);
  });

  testWidgets('every cell is a labelled button and today says it is today', (tester) async {
    final handle = tester.ensureSemantics();
    final now = DateTime.now();
    final other = now.day == 1 ? 2 : 1;
    await tester.pumpWidget(app(const []));

    expect(find.bySemanticsLabel(RegExp('${months[now.month - 1]} ${now.day}, ${now.year}, today')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('${months[now.month - 1]} $other, ${now.year}')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the arrows step one month and the six rows keep their height', (tester) async {
    await tester.pumpWidget(app(const [], initialMonth: DateTime(2026, 1, 15)));
    expect(find.text('January 2026'), findsOneWidget);
    final height = tester.getSize(find.byType(MonthCalendar)).height;

    await tester.tap(find.byTooltip('Next month'));
    await tester.pump();
    expect(find.text('February 2026'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous month'));
    await tester.pump();
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pump();
    expect(find.text('December 2025'), findsOneWidget);
    expect(find.byKey(dayKey(DateTime(2025, 12, 29))), findsOneWidget);
    // A cell from the next month belongs to the visible grid too.
    expect(find.byKey(dayKey(DateTime(2026, 1, 4))), findsOneWidget);
    expect(tester.getSize(find.byType(MonthCalendar)).height, height);
  });

  testWidgets('a horizontal swipe changes the month', (tester) async {
    await tester.pumpWidget(app(const [], initialMonth: DateTime(2026, 1, 15)));
    expect(find.text('January 2026'), findsOneWidget);

    await tester.fling(find.byType(MonthCalendar), const Offset(-320, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('February 2026'), findsOneWidget);

    await tester.fling(find.byType(MonthCalendar), const Offset(320, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('January 2026'), findsOneWidget);
  });

  testWidgets('tapping the title returns to the current month', (tester) async {
    await tester.pumpWidget(app(const [], initialMonth: DateTime(2025, 2, 10)));
    expect(find.text('February 2025'), findsOneWidget);

    await tester.tap(find.text('February 2025'));
    await tester.pump();

    final now = DateTime.now();
    expect(find.text('${months[now.month - 1]} ${now.year}'), findsOneWidget);
  });

  testWidgets('tapping a day reports its local midnight, outside days included', (tester) async {
    final picked = <DateTime>[];
    await tester.pumpWidget(app(
      const [],
      initialMonth: DateTime(2026, 3, 1),
      onDaySelected: picked.add,
    ));

    await tester.tap(find.byKey(dayKey(DateTime(2026, 3, 15))));
    await tester.pump();
    expect(picked.single, DateTime(2026, 3, 15));
    expect(picked.single.hour, 0);
    expect(picked.single.isUtc, isFalse);

    // March 2026 starts on a Sunday, so the grid opens on 23 February.
    await tester.tap(find.byKey(dayKey(DateTime(2026, 2, 23))));
    await tester.pump();
    expect(picked.last, DateTime(2026, 2, 23));
  });

  testWidgets('a day shows a dot per task, muted when everything is done', (tester) async {
    await tester.pumpWidget(app(
      [
        task('a', '2026-03-10'),
        task('b', '2026-03-10'),
        task('c', '2026-03-12', done: true),
      ],
      initialMonth: DateTime(2026, 3, 1),
    ));

    final busy = DateTime(2026, 3, 10);
    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    expect(dotsOn(busy), findsNWidgets(2));
    expect(tester.widget<Icon>(dotsOn(busy).first).color?.toARGB32(), scheme.primary.toARGB32());

    final done = DateTime(2026, 3, 12);
    expect(dotsOn(done), findsOneWidget);
    expect(tester.widget<Icon>(dotsOn(done)).color?.toARGB32(), scheme.outline.toARGB32());

    expect(dotsOn(DateTime(2026, 3, 11)), findsNothing);
  });

  testWidgets('bigger counts collapse to a number, then to 9+', (tester) async {
    await tester.pumpWidget(app(
      [
        for (var i = 0; i < 4; i++) task('four$i', '2026-04-07'),
        for (var i = 0; i < 10; i++) task('ten$i', '2026-04-08'),
      ],
      initialMonth: DateTime(2026, 4, 1),
    ));

    expect(
      find.descendant(of: find.byKey(dayKey(DateTime(2026, 4, 7))), matching: find.text('4')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(dayKey(DateTime(2026, 4, 8))), matching: find.text('9+')),
      findsOneWidget,
    );
    expect(dotsOn(DateTime(2026, 4, 7)), findsNothing);
  });

  testWidgets('tapping a day moves the highlight and today keeps its mark', (tester) async {
    final now = DateTime.now();
    final other = now.day == 1 ? DateTime(now.year, now.month, 2) : DateTime(now.year, now.month, 1);
    await tester.pumpWidget(app(const [], initialMonth: now));

    await tester.tap(find.byKey(dayKey(other)));
    await tester.pump();

    expect(find.byKey(const Key('calendar-selected')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(dayKey(other)), matching: find.byKey(const Key('calendar-selected'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(dayKey(now)), matching: find.byKey(const Key('calendar-today'))),
      findsOneWidget,
    );
  });
}
