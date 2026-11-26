import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/app_state.dart';
import 'package:otda/src/security/app_lock.dart';
import 'package:otda/src/ui/app_lock_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppLock.instance.setEnabled(false));

  test('the lock starts engaged and unlocking is separate from disabling', () {
    AppLock.instance.setEnabled(true);
    expect(AppLock.instance.enabled, isTrue);
    expect(AppLock.instance.locked, isTrue);

    AppLock.instance.unlockForSession();
    expect(AppLock.instance.locked, isFalse);
    expect(AppLock.instance.enabled, isTrue);

    AppLock.instance.lockNow();
    expect(AppLock.instance.locked, isTrue);

    AppLock.instance.setEnabled(false);
    expect(AppLock.instance.locked, isFalse);
  });

  testWidgets('the gate hides signed-in content while locked', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    AppLock.instance.setEnabled(true);

    await tester.pumpWidget(
      MaterialApp(home: AppLockGate(state: state, child: const Text('SECRET TASKS'))),
    );
    expect(find.text('OTDA is locked'), findsOneWidget);
    expect(find.text('SECRET TASKS'), findsNothing);

    // Let the one-shot auto-prompt fire. There is no platform auth channel in the
    // test, so it resolves to the "set a screen lock" message and leaves the gate up.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    AppLock.instance.setEnabled(false);
    await tester.pump();
    expect(find.text('SECRET TASKS'), findsOneWidget);
  });
}
