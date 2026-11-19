// The brand mark must lay out at any size without the asset bundle's help, so
// a missing logo can never take the About card or the sign-in screen down.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/ui/widgets.dart';

void main() {
  testWidgets('BrandMark keeps its square size', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: BrandMark(size: 72))),
    ));
    expect(tester.getSize(find.byType(BrandMark)), const Size(72, 72));
  });
}
