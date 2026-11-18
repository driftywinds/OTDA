import 'package:material_ui/material_ui.dart';

/// OTDA's look: a calm indigo on soft neutral surfaces, white cards that float
/// just above the page, generous radii, quiet type. Material 3, light and dark.
const _seed = Color(0xFF5B5BD6);

const _lightPage = Color(0xFFF6F6F9);
const _lightCard = Color(0xFFFFFFFF);
const _darkPage = Color(0xFF111114);
const _darkCard = Color(0xFF1C1C21);

/// Surface tokens the stock [ColorScheme] has no good slot for.
extension OtdaColors on ColorScheme {
  bool get _isDark => brightness == Brightness.dark;

  /// The page behind everything.
  Color get page => _isDark ? _darkPage : _lightPage;

  /// A row or panel sitting on the page.
  Color get card => _isDark ? _darkCard : _lightCard;

  /// A hairline between things on a card.
  Color get hairline => outlineVariant.withValues(alpha: _isDark ? 0.5 : 0.7);

  /// A fill for inputs and unselected controls, slightly off the card.
  Color get field => _isDark ? const Color(0xFF26262D) : const Color(0xFFEFEFF4);
}

/// Priority colours: P1 red, P2 amber, P3 blue, P4 neutral. Fixed hues so a
/// priority reads the same in every theme.
Color priorityColor(int priority, ColorScheme scheme) => switch (priority) {
      1 => const Color(0xFFE5484D),
      2 => const Color(0xFFF08A24),
      3 => const Color(0xFF3E8BE0),
      _ => scheme.outline,
    };

ThemeData buildTheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final scheme = base.copyWith(surface: brightness == Brightness.dark ? _darkPage : _lightPage);
  final radius = BorderRadius.circular(14);

  OutlineInputBorder fieldBorder([Color color = Colors.transparent, double width = 1]) =>
      OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: color, width: width));

  // Start from the stock sizes, coloured from this scheme, then tune weights.
  final text = ThemeData(colorScheme: scheme, useMaterial3: true).textTheme;
  final textTheme = text.copyWith(
    headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8),
    titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
    titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
    bodyLarge: text.bodyLarge?.copyWith(letterSpacing: -0.1),
    labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
    labelMedium: text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.page,
    textTheme: textTheme,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.page,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: fieldBorder(),
      enabledBorder: fieldBorder(),
      focusedBorder: fieldBorder(scheme.primary, 1.6),
      errorBorder: fieldBorder(scheme.error),
      focusedErrorBorder: fieldBorder(scheme.error, 1.6),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.card,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: textTheme.labelLarge,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide.none,
        backgroundColor: scheme.field,
        selectedBackgroundColor: scheme.card,
        selectedForegroundColor: scheme.onSurface,
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      highlightElevation: 3,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      backgroundColor: scheme.card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.14),
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => textTheme.labelMedium?.copyWith(
            fontSize: 12,
            color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
          )),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
          )),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.card,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: scheme.card,
      showDragHandle: true,
      dragHandleColor: scheme.outlineVariant,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.card,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(color: scheme.hairline, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
