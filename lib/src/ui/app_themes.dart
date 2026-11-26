import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'theme.dart';

/// The light and dark themes the person's appearance settings describe: accent,
/// font, density, AMOLED black and the instance palette. The app and the widget's
/// quick-add popup both build theirs here, so the popup looks like the app.
class AppThemes {
  const AppThemes({required this.light, required this.dark, required this.mode});

  final ThemeData light;
  final ThemeData dark;
  final ThemeMode mode;
}

AppThemes buildAppThemes(AppState state) {
  final accent = _color(state.accentHex);
  final density = state.compact ? VisualDensity.compact : VisualDensity.standard;
  final font = state.useAllo ? alloFont : null;
  return AppThemes(
    mode: state.themeMode,
    light: buildTheme(
      Brightness.light,
      fontFamily: font,
      seed: accent,
      palette: _palette(state.instanceLightSeeds, accent),
      density: density,
    ),
    dark: buildTheme(
      Brightness.dark,
      fontFamily: font,
      amoled: state.amoled,
      seed: accent,
      palette: _palette(state.instanceDarkSeeds, accent),
      density: density,
    ),
  );
}

Color? _color(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final value = int.tryParse(hex.substring(1), radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

OtdaPalette? _palette(Map<String, dynamic>? seeds, Color? accent) {
  if (seeds == null) return null;
  final base = OtdaPalette.fromSeeds(seeds);
  return accent == null
      ? base
      : OtdaPalette(accent: accent, page: base.page, card: base.card, text: base.text);
}
