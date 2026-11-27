import 'package:material_ui/material_ui.dart';

import 'package:home_widget/home_widget.dart';

import 'src/util/log.dart';
import 'src/app_state.dart';
import 'src/headless_action_app.dart';
import 'src/quick_add_app.dart';
import 'src/reminder_sheet_app.dart';
import 'src/task_sheet_app.dart';
import 'src/reminders/service.dart';
import 'src/system_bridge.dart';
import 'src/security/app_lock.dart';
import 'src/ui/app_lock_screen.dart';
import 'src/ui/connect_screen.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/mfa_enrolment_screen.dart';
import 'src/ui/sync_gate_screen.dart';
import 'src/ui/app_themes.dart';

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

/// Entry point of ReminderSheetActivity: the bottom drawer a tap on a reminder opens.
@pragma('vm:entry-point')
void reminderSheetMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReminderSheetApp());
}

/// Entry point of TaskSheetActivity: the task's own sheet, opened by a tap on a widget row.
@pragma('vm:entry-point')
void taskSheetMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TaskSheetApp());
}

class OtdaApp extends StatefulWidget {
  const OtdaApp({super.key});

  @override
  State<OtdaApp> createState() => _OtdaAppState();
}

class _OtdaAppState extends State<OtdaApp> with WidgetsBindingObserver {
  final _state = AppState();

  /// A short app switch does not immediately demand authentication. Encryption
  /// is not locked here: this clock only drives the separate app lock.
  DateTime? _leftAt;
  static const _appLockGrace = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _leftAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      final left = _leftAt;
      _leftAt = null;
      if (left != null && DateTime.now().difference(left) > _appLockGrace) {
        AppLock.instance.lockNow();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      key: const ValueKey('otda-state'),
      animation: _state,
      builder: (context, _) {
        // These read the live state. Computing them outside the builder made the
        // accent (and density) stick at whatever they were when OtdaApp first
        // built: the AnimatedBuilder rebuilt, but its closure kept the old theme.
        final themes = buildAppThemes(_state);
        final signedIn = _state.mfaEnrolmentRequired
            ? MfaEnrolmentScreen(state: _state)
            : _state.isReady
                ? HomeScreen(state: _state)
                : SyncGateScreen(state: _state);
        return AnimatedBuilder(
          animation: AppLock.instance,
          builder: (context, _) => MaterialApp(
            title: 'OTDA',
            debugShowCheckedModeBanner: false,
            themeMode: themes.mode,
            theme: themes.light,
            darkTheme: themes.dark,
            // The appearance slider multiplies the phone's own text scale rather than
            // replacing it, so accessibility settings still apply.
            builder: (context, child) {
              final system = MediaQuery.textScalerOf(context).scale(1);
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(system * _state.textScale),
                ),
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: _state.isRestoring
                ? const Scaffold(body: Center(child: CircularProgressIndicator()))
                : !_state.isSignedIn
                    ? ConnectScreen(state: _state)
                    : AppLockGate(state: _state, child: signedIn),
          ),
        );
      },
    );
  }
}
