import 'package:material_ui/material_ui.dart';

import 'reminders/debug_log.dart';
import 'reminders/service.dart';
import 'system_bridge.dart';
import 'ui/new_task_sheet.dart';
import 'ui/theme.dart';

/// The widget's "+" popup: the same composer as the app's plus button, in a
/// see-through window over whatever app is in front. It opens the replica without
/// the main app, saves the task, re-arms reminders and refreshes the widget, then
/// closes itself. The task reaches the server the next time the app syncs.
class QuickAddApp extends StatelessWidget {
  const QuickAddApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const _QuickAddHost(),
    );
  }
}

class _QuickAddHost extends StatefulWidget {
  const _QuickAddHost();

  @override
  State<_QuickAddHost> createState() => _QuickAddHostState();
}

class _QuickAddHostState extends State<_QuickAddHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    try {
      final repo = await openHeadlessRepo();
      final projectId = await SystemBridge.quickAddProject();
      final projects = await repo.projects();
      if (!mounted) return;
      final created = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => NewTaskSheet(repo: repo, projects: projects, initialProjectId: projectId),
      );
      if (created == true) {
        await DebugLog.add('quick add: task created', source: 'popup');
        await ReminderService.instance.rearmFrom(repo);
        await pushWidgetsFromRepo(repo);
      }
    } on Object catch (e) {
      await DebugLog.add('quick add FAILED: $e', source: 'popup');
    } finally {
      await SystemBridge.closeQuickAdd();
    }
  }

  @override
  Widget build(BuildContext context) => const Scaffold(backgroundColor: Colors.transparent);
}
