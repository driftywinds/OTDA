import 'package:material_ui/material_ui.dart';

/// OTDA's look: a calm indigo on soft neutral surfaces, cards outlined by a
/// hairline and lifted by a barely-there shadow, generous radii, tight type.
/// Material 3, light and dark.
const _seed = Color(0xFF5B5BD6);

const _lightPage = Color(0xFFF4F4F8);
const _lightCard = Color(0xFFFFFFFF);
const _darkPage = Color(0xFF0F0F13);
const _darkCard = Color(0xFF1A1A20);

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
  Color get field => _isDark ? const Color(0xFF25252D) : const Color(0xFFEDEDF3);

  /// The outline that separates a card from the page.
  Color get cardBorder => _isDark ? const Color(0xFF2A2A33) : const Color(0xFFE7E7EE);

  /// A soft lift for cards; dark surfaces separate by outline alone.
  List<BoxShadow> get softShadow => _isDark
      ? const []
      : const [
          BoxShadow(color: Color(0x0D1B1B3A), blurRadius: 14, offset: Offset(0, 4)),
          BoxShadow(color: Color(0x08000000), blurRadius: 2, offset: Offset(0, 1)),
        ];

  /// The brand wash used on the logo, avatars and the workspace tile.
  LinearGradient get brandGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [primary, Color.lerp(primary, tertiary, 0.75)!],
      );
}

/// Priority colours: P1 red, P2 amber, P3 blue, P4 neutral. Fixed hues so a
/// priority reads the same in every theme.
Color priorityColor(int priority, ColorScheme scheme) => switch (priority) {
      1 => const Color(0xFFE5484D),
      2 => const Color(0xFFF08A24),
      3 => const Color(0xFF3E8BE0),
      _ => scheme.outline,
    };

/// The bundled faces a person can choose from. A null family is the
/// platform's own font.
const alloFont = 'Allo';

ThemeData buildTheme(Brightness brightness, {String? fontFamily}) {
  final base = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final scheme = base.copyWith(surface: brightness == Brightness.dark ? _darkPage : _lightPage);
  final radius = BorderRadius.circular(14);
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
    side: BorderSide(color: scheme.cardBorder),
  );

  OutlineInputBorder fieldBorder([Color color = Colors.transparent, double width = 1]) =>
      OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: color, width: width));

  // Start from the stock sizes, coloured from this scheme, then tune weights.
  // The family has to be on the ThemeData the text theme is derived from: a
  // `textTheme:` passed in explicitly wins over `ThemeData.fontFamily`, so
  // building these styles without it is why choosing Allo changed nothing.
  final text = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: fontFamily).textTheme;
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
    fontFamily: fontFamily,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.page,
    textTheme: textTheme,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.page,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      actionsIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
      prefixIconColor: scheme.onSurfaceVariant,
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
      shape: cardShape,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primary.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.card,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.label,
      indicatorColor: scheme.primary,
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: textTheme.labelLarge,
      unselectedLabelStyle: textTheme.labelLarge,
      dividerColor: scheme.hairline,
      overlayColor: WidgetStatePropertyAll(scheme.primary.withValues(alpha: 0.06)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.cardBorder, width: 1.2),
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
      elevation: 4,
      highlightElevation: 6,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
      elevation: 8,
      shadowColor: const Color(0x331B1B3A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.cardBorder),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.hairline, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
