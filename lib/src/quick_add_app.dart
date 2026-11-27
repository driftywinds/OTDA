import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'reminders/debug_log.dart';
import 'reminders/service.dart';
import 'system_bridge.dart';
import 'ui/new_task_sheet.dart';
import 'ui/app_themes.dart';

/// The widget's "+" popup: the same composer as the app's plus button, in a
/// see-through window over whatever app is in front. It opens the replica without
/// the main app, saves the task, re-arms reminders and refreshes the widget, then
/// closes itself. The task reaches the server the next time the app syncs.
class QuickAddApp extends StatelessWidget {
  const QuickAddApp({super.key});

  @override
  Widget build(BuildContext context) => const PopupShell(home: _QuickAddHost());
}

/// The themed, see-through app both popups (the "+" composer and the reminder drawer) run in.
class PopupShell extends StatefulWidget {
  const PopupShell({super.key, required this.home});

  final Widget home;

  @override
  State<PopupShell> createState() => _PopupShellState();
}

class _PopupShellState extends State<PopupShell> {
  // The popup runs in its own engine with no session, but the appearance settings
  // are device preferences: reading them here is what makes it wear the app's
  // accent, font, density and dark style instead of the stock look.
  final _state = AppState();

  @override
  void initState() {
    super.initState();
    _state.loadLocalPreferences();
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
      builder: (context, _) {
        final themes = buildAppThemes(_state);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: themes.mode,
          theme: themes.light,
          darkTheme: themes.dark,
          builder: (context, child) {
            final system = MediaQuery.textScalerOf(context).scale(1);
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(system * _state.textScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: widget.home,
        );
      },
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
