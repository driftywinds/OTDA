import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/ui/notes_field.dart';

void main() {
  testWidgets('notes render a checklist and a tap writes the Markdown', (tester) async {
    final controller = TextEditingController(text: '- [ ] one\n- [x] two');
    var saves = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: NotesField(
          controller: controller,
          onSave: () async => saves++,
        ),
      ),
    ));
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.check_box_outline_blank_rounded));
    await tester.pump();
    expect(controller.text, '- [x] one\n- [x] two');
    expect(saves, 1);
  });

  testWidgets('notes headings and bold are rendered, not shown as markup', (tester) async {
    final controller = TextEditingController(text: '# Heading\n\nA **bold** line.');
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: NotesField(controller: controller, onSave: () async {}),
      ),
    ));
    expect(find.text('Heading'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });
}
