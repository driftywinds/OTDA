import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/main.dart';
import 'package:otda/src/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('changing the accent rebuilds the app theme', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const OtdaApp());
    await tester.pump();

    final builder = tester.widget<AnimatedBuilder>(find.byKey(const ValueKey('otda-state')));
    final state = builder.animation as AppState;
    final before = tester.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!.colorScheme.primary;

    await state.setAccent('#EF4444');
    await tester.pump(const Duration(milliseconds: 400));

    final after = tester.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!.colorScheme.primary;
    expect(after, isNot(before));
  });
}
