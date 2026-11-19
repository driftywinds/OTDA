import 'package:material_ui/material_ui.dart';

import 'package:home_widget/home_widget.dart';

import 'src/app_state.dart';
import 'src/reminders/service.dart';
import 'src/system_bridge.dart';
import 'src/ui/connect_screen.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OtdaApp());
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
    return AnimatedBuilder(
      animation: _state,
      builder: (context, _) => MaterialApp(
        title: 'OTDA',
        debugShowCheckedModeBanner: false,
        themeMode: _state.themeMode,
        theme: buildTheme(Brightness.light, fontFamily: _state.useAllo ? alloFont : null),
        darkTheme: buildTheme(
          Brightness.dark,
          fontFamily: _state.useAllo ? alloFont : null,
          amoled: _state.amoled,
        ),
        home: _state.isRestoring
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : _state.isSignedIn
                ? HomeScreen(state: _state)
                : ConnectScreen(state: _state),
      ),
    );
  }
}
