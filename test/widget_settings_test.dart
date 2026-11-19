import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/widget/widget_settings.dart';

void main() {
  test('defaults match the native side', () {
    final p = const WidgetSettings().toPrefs();
    expect(p, {
      'widget_text_scale': 100,
      'widget_density': 'standard',
      'widget_theme': 'system',
      'widget_background': 100,
      'widget_show_sections': true,
      'widget_show_due': true,
      'widget_show_completed': true,
    });
  });

  test('values round-trip through the preference map', () {
    const s = WidgetSettings(
      textScalePct: 130,
      density: 'compact',
      theme: 'dark',
      backgroundPct: 60,
      showSections: false,
      showDue: false,
      showCompleted: false,
    );
    final back = WidgetSettings.fromPrefs((k) => s.toPrefs()[k]);
    expect(back.toPrefs(), s.toPrefs());
  });

  test('missing, odd or out-of-range values fall back or clamp', () {
    final odd = {
      'widget_text_scale': 999,
      'widget_density': 'huge',
      'widget_theme': 7,
      'widget_background': '5',
      'widget_show_due': 'yes',
    };
    final s = WidgetSettings.fromPrefs((k) => odd[k]);
    expect(s.textScalePct, 160);
    expect(s.density, 'standard');
    expect(s.theme, 'system');
    expect(s.backgroundPct, 20);
    expect(s.showDue, isTrue);
  });
}
