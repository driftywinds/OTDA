import 'package:material_ui/material_ui.dart';

import 'package:home_widget/home_widget.dart';

import 'src/util/log.dart';
import 'src/app_state.dart';
import 'src/headless_action_app.dart';
import 'src/quick_add_app.dart';
import 'src/reminders/service.dart';
import 'src/system_bridge.dart';
import 'src/ui/connect_screen.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/mfa_enrolment_screen.dart';
import 'src/ui/sync_gate_screen.dart';
import 'src/ui/theme.dart';

void main() {
  otdaLog('--- app start ---');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OtdaApp());
}

/// Entry point of CompleteActivity: the widget's check mark, run invisibly.
@pragma('vm:entry-point')
void completeMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HeadlessActionApp());
}

/// Entry point of QuickAddActivity, the widget's "+" popup. It must live in this
/// library: the Android side looks the function up by name in main.dart.
@pragma('vm:entry-point')
void quickAddMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QuickAddApp());
}

class OtdaApp extends StatefulWidget {
  const OtdaApp({super.key});

  @override
  State<OtdaApp> createState() => _OtdaAppState();
}

class _OtdaAppState extends State<OtdaApp> {
  final _state = AppState();

  @override
  void initState() {
    super.initState();
    _state.loadLocalPreferences();
    _state.restore();
    ReminderService.instance.init();
    HomeWidget.registerInteractivityCallback(onWidgetAction);
    // otda:// links (widget rows, the widget's "+", a notification) arrive from
    // MainActivity: home_widget only reports its own launch action, which plain
    // deep-link intents do not use.
    SystemBridge.listen(handleWidgetUri);
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _color(_state.accentHex);
    final lightPalette = _palette(_state.instanceLightSeeds, accent);
    final darkPalette = _palette(_state.instanceDarkSeeds, accent);
    final density = _state.compact ? VisualDensity.compact : VisualDensity.standard;
    return AnimatedBuilder(
      animation: _state,
      builder: (context, _) => MaterialApp(
        title: 'OTDA',
        debugShowCheckedModeBanner: false,
        themeMode: _state.themeMode,
        theme: buildTheme(
          Brightness.light,
          fontFamily: _state.useAllo ? alloFont : null,
          seed: accent,
          palette: lightPalette,
          density: density,
        ),
        darkTheme: buildTheme(
          Brightness.dark,
          fontFamily: _state.useAllo ? alloFont : null,
          amoled: _state.amoled,
          seed: accent,
          palette: darkPalette,
          density: density,
        ),
        home: _state.isRestoring
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : !_state.isSignedIn
                ? ConnectScreen(state: _state)
                : _state.mfaEnrolmentRequired
                    ? MfaEnrolmentScreen(state: _state)
                    : _state.isReady
                        ? HomeScreen(state: _state)
                        : SyncGateScreen(state: _state),
      ),
    );
  }

  static Color? _color(String? hex) {
    if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
    final value = int.tryParse(hex.substring(1), radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  static OtdaPalette? _palette(Map<String, dynamic>? seeds, Color? accent) {
    if (seeds == null) return null;
    final base = OtdaPalette.fromSeeds(seeds);
    return accent == null
        ? base
        : OtdaPalette(accent: accent, page: base.page, card: base.card, text: base.text);
  }
}
