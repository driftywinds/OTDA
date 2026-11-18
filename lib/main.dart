import 'package:material_ui/material_ui.dart';

import 'src/app_state.dart';
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
    _state.restore();
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
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: _state.isRestoring
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : _state.isSignedIn
                ? HomeScreen(state: _state)
                : ConnectScreen(state: _state),
      ),
    );
  }
}
