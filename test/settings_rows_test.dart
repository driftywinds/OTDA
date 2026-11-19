// Every settings value has to end on the same line, whatever the row type, and
// the split must be by flex so it holds at any width.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/ui/settings_rows.dart';

Widget application(List<Widget> rows) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: Card(
              child: Column(children: rows),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a plain value and a choice value share one right edge', (tester) async {
    await tester.pumpWidget(application([
      const SettingsRow(label: 'Server version', value: 'v1.5.0'),
      SettingsChoiceRow(
        label: 'Week starts on',
        value: 'mon',
        options: const {'mon': 'Monday'},
        onChanged: (_) {},
      ),
    ]));

    final plain = tester.getTopRight(find.text('v1.5.0')).dx;
    final choice = tester.getTopRight(find.text('Monday')).dx;
    expect(plain, moreOrLessEquals(choice, epsilon: 0.5));
  });

  testWidgets('a long value is shortened rather than pushing the layout', (tester) async {
    await tester.pumpWidget(application([
      const SettingsRow(label: 'Signed in with', value: 'Password (session) with a very long tail'),
    ]));

    final text = tester.widget<Text>(find.textContaining('Password'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    // The label keeps its own room instead of being squeezed out.
    expect(tester.getSize(find.text('Signed in with')).width, greaterThan(60));
  });

  testWidgets('the row text is smaller than the body default', (tester) async {
    await tester.pumpWidget(application([
      const SettingsRow(label: 'Email', value: 'hi@example.com'),
    ]));
    final style = tester.widget<Text>(find.text('hi@example.com')).style;
    expect(style?.fontSize, 13);
  });
}
