import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the weekly progress card is off by default and persists when enabled', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AppState();
    await first.loadLocalPreferences();
    expect(first.showWeekStats, isFalse);

    await first.setShowWeekStats(true);
    expect(first.showWeekStats, isTrue);

    final second = AppState();
    await second.loadLocalPreferences();
    expect(second.showWeekStats, isTrue);
  });
}
