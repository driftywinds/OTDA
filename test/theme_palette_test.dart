import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/data/instance_theme.dart';
import 'package:otda/src/ui/theme.dart';

void main() {
  test('the instance default names an instance theme, side by side', () {
    final seeds = instanceThemeSeeds({
      'version': 3,
      'default': {'light': 'instance:paper', 'dark': 'builtin:opentodo-dark'},
      'themes': [
        {
          'id': 'paper',
          'seeds': {'accent': '#2f6fb0', 'canvas': '#f4f1ea'},
        },
        {
          'id': 'nord',
          'seeds': {'accent': '#88c0d0', 'canvas': '#2e3440'},
        },
      ],
    });
    expect(seeds.light?['accent'], '#2f6fb0');
    expect(seeds.dark, isNull, reason: 'a built-in default keeps the app palette');

    final byId = instanceThemeSeeds({
      'default': {'light': '', 'dark': 'instance:nord'},
      'themes': [
        {
          'id': 'nord',
          'seeds': {'accent': '#88c0d0'},
        },
      ],
    });
    expect(byId.light, isNull);
    expect(byId.dark?['accent'], '#88c0d0');
  });

  test('instance theme seeds become a palette, with OpenTodo values as fallback', () {
    final palette = OtdaPalette.fromSeeds({
      'accent': '#88c0d0',
      'canvas': '#2e3440',
      'surface': '#3b4252',
      'text': '#eceff4',
    });
    expect(palette.accent, const Color(0xFF88C0D0));
    expect(palette.page, const Color(0xFF2E3440));
    expect(palette.card, const Color(0xFF3B4252));
    expect(palette.text, const Color(0xFFECEFF4));

    final fallback = OtdaPalette.fromSeeds({'accent': 'url(https://example.com/x.png)'});
    expect(fallback.accent, isNot(const Color(0xFF000000)));
  });

  test('a palette drives the page, card and accent, and density is applied', () {
    const palette = OtdaPalette(
      accent: Color(0xFF88C0D0),
      page: Color(0xFF2E3440),
      card: Color(0xFF3B4252),
      text: Color(0xFFECEFF4),
    );
    final theme = buildTheme(
      Brightness.dark,
      palette: palette,
      density: VisualDensity.compact,
    );
    expect(theme.colorScheme.surface, palette.page);
    expect(theme.colorScheme.surfaceContainerLow, palette.card);
    expect(theme.colorScheme.onSurface, palette.text);
    expect(theme.colorScheme.primary, isNot(Colors.transparent));
    expect(theme.visualDensity, VisualDensity.compact);

    final own = buildTheme(Brightness.light, seed: const Color(0xFF22C55E));
    expect(own.colorScheme.brightness, Brightness.light);
    expect(own.colorScheme.primary, isNot(theme.colorScheme.primary));
  });
}
