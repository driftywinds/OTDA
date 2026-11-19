import 'package:home_widget/home_widget.dart';

/// How the home-screen widget looks, kept on this device.
///
/// The values live in the same store the widget's snapshot does (home_widget's
/// shared preferences), under the keys the Kotlin side reads in `WidgetStyle.read`.
/// They are whole numbers, strings and booleans only, so the native side needs no
/// special decoding. Keep the keys and the defaults in step with `TasksWidget.kt`.
class WidgetSettings {
  const WidgetSettings({
    this.textScalePct = 100,
    this.density = 'standard',
    this.theme = 'system',
    this.backgroundPct = 100,
    this.showSections = true,
    this.showDue = true,
    this.showCompleted = true,
  });

  static const int minTextScale = 70;
  static const int maxTextScale = 160;
  static const int minBackground = 20;
  static const int maxBackground = 100;

  /// Text size as a percentage of the default (100).
  final int textScalePct;

  /// Row spacing: `compact`, `standard` or `roomy`.
  final String density;

  /// `system` (follows the phone), `light` or `dark`.
  final String theme;

  /// How opaque the widget's background is, in percent.
  final int backgroundPct;

  /// Show the Overdue / Today / Tomorrow headings.
  final bool showSections;

  /// Show the due time or date at the right of each row.
  final bool showDue;

  /// Keep completed tasks in the list.
  final bool showCompleted;

  static const keyTextScale = 'widget_text_scale';
  static const keyDensity = 'widget_density';
  static const keyTheme = 'widget_theme';
  static const keyBackground = 'widget_background';
  static const keySections = 'widget_show_sections';
  static const keyDue = 'widget_show_due';
  static const keyCompleted = 'widget_show_completed';

  WidgetSettings copyWith({
    int? textScalePct,
    String? density,
    String? theme,
    int? backgroundPct,
    bool? showSections,
    bool? showDue,
    bool? showCompleted,
  }) =>
      WidgetSettings(
        textScalePct: (textScalePct ?? this.textScalePct).clamp(minTextScale, maxTextScale),
        density: density ?? this.density,
        theme: theme ?? this.theme,
        backgroundPct: (backgroundPct ?? this.backgroundPct).clamp(minBackground, maxBackground),
        showSections: showSections ?? this.showSections,
        showDue: showDue ?? this.showDue,
        showCompleted: showCompleted ?? this.showCompleted,
      );

  /// What gets written to the shared preferences.
  Map<String, Object> toPrefs() => {
        keyTextScale: textScalePct,
        keyDensity: density,
        keyTheme: theme,
        keyBackground: backgroundPct,
        keySections: showSections,
        keyDue: showDue,
        keyCompleted: showCompleted,
      };

  /// Reads settings back from a key → value lookup; anything missing or out of
  /// range falls back to the default, so a half-written store never breaks the widget.
  static WidgetSettings fromPrefs(Object? Function(String key) read) {
    const d = WidgetSettings();
    int number(String key, int fallback) {
      final v = read(key);
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    bool flag(String key, bool fallback) {
      final v = read(key);
      return v is bool ? v : fallback;
    }

    String choice(String key, Set<String> allowed, String fallback) {
      final v = read(key);
      return v is String && allowed.contains(v) ? v : fallback;
    }

    return d.copyWith(
      textScalePct: number(keyTextScale, d.textScalePct),
      density: choice(keyDensity, const {'compact', 'standard', 'roomy'}, d.density),
      theme: choice(keyTheme, const {'system', 'light', 'dark'}, d.theme),
      backgroundPct: number(keyBackground, d.backgroundPct),
      showSections: flag(keySections, d.showSections),
      showDue: flag(keyDue, d.showDue),
      showCompleted: flag(keyCompleted, d.showCompleted),
    );
  }

  static Future<WidgetSettings> load() async {
    try {
      final values = <String, Object?>{};
      for (final key in const WidgetSettings().toPrefs().keys) {
        values[key] = await HomeWidget.getWidgetData<Object>(key);
      }
      return fromPrefs((key) => values[key]);
    } on Object {
      return const WidgetSettings();
    }
  }

  /// Writes every value and asks the launcher to redraw the widget. A device with no
  /// widget placed, or no launcher support, is not an error.
  Future<void> save() async {
    try {
      for (final entry in toPrefs().entries) {
        final value = entry.value;
        if (value is int) {
          await HomeWidget.saveWidgetData<int>(entry.key, value);
        } else if (value is bool) {
          await HomeWidget.saveWidgetData<bool>(entry.key, value);
        } else {
          await HomeWidget.saveWidgetData<String>(entry.key, value as String);
        }
      }
      await HomeWidget.updateWidget(
        androidName: 'TasksWidgetReceiver',
        qualifiedAndroidName: 'com.dw.otda.widget.TasksWidgetReceiver',
      );
    } on Object {
      // nothing to redraw
    }
  }
}
