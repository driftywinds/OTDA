// The task sheet's value chips: one height for every chip, whether it has a cross, a chevron or
// neither, and a grid of two equal columns instead of a ragged flow.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/ui/widgets.dart';

void main() {
  Widget host(List<ValueChip> chips) => MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: 360, child: ChipGrid(chips: chips)),
          ),
        ),
      );

  Rect rectOf(WidgetTester tester, String label) =>
      tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(ValueChip)).first);

  testWidgets('chips share one height and sit on two equal columns', (tester) async {
    await tester.pumpWidget(host([
      ValueChip(label: 'Aug 31', icon: Icons.event_rounded, onTap: () {}, onClear: () {}),
      ValueChip(label: '06:00', icon: Icons.schedule_rounded, onTap: () {}, onClear: () {}),
      ValueChip(label: 'every day', icon: Icons.repeat_rounded, onTap: () {}, onClear: () {}),
      ValueChip(label: 'Main', icon: Icons.folder_outlined, dropdown: true, onTap: () {}),
    ]));

    final rects = [for (final label in ['Aug 31', '06:00', 'every day', 'Main']) rectOf(tester, label)];
    for (final rect in rects) {
      expect(rect.height, ValueChip.height);
      expect(rect.width, closeTo(176, 0.5), reason: '(360 - 8) / 2');
    }
    expect(rects[0].top, rects[1].top);
    expect(rects[2].top, rects[3].top);
    expect(rects[2].top, greaterThan(rects[0].bottom));
    expect(rects[1].left, greaterThan(rects[0].right));
  });

  testWidgets('a long label takes a whole row', (tester) async {
    await tester.pumpWidget(host([
      ValueChip(label: 'Due by Wed, Sep 3', onTap: () {}),
      ValueChip(label: 'Main', onTap: () {}),
    ]));
    expect(rectOf(tester, 'Due by Wed, Sep 3').width, closeTo(360, 0.5));
    expect(rectOf(tester, 'Main').top, greaterThan(rectOf(tester, 'Due by Wed, Sep 3').bottom));
  });
}
