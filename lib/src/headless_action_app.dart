import 'package:material_ui/material_ui.dart';

import 'reminders/service.dart';
import 'system_bridge.dart';

/// Entry point of CompleteActivity: runs one widget action with no visible UI, then
/// closes itself. Kept in its own library-like app so it never builds the full shell.
@pragma('vm:entry-point')
void completeMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HeadlessActionApp());
}

class HeadlessActionApp extends StatefulWidget {
  const HeadlessActionApp({super.key});

  @override
  State<HeadlessActionApp> createState() => _HeadlessActionAppState();
}

class _HeadlessActionAppState extends State<HeadlessActionApp> {
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final raw = await SystemBridge.completeUri();
      if (raw != null && raw.isNotEmpty) {
        await onWidgetAction(Uri.parse(raw));
      }
    } on Object {
      // An action that cannot run must still close: the activity is invisible, and a
      // stuck one would hold the process.
    } finally {
      await SystemBridge.closeComplete();
    }
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0x00000000), child: SizedBox.expand());
}
