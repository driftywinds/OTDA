import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart' show AppState;
import 'data/repo.dart';
import 'e2ee/session.dart';
import 'quick_add_app.dart' show PopupShell;
import 'reminders/debug_log.dart';
import 'reminders/service.dart';
import 'system_bridge.dart';
import 'ui/task_sheet.dart';

/// What a tap on a widget row opens: the task's own sheet (title, date, repeat, project, notes...) as a
/// bottom drawer over whatever app is in front, instead of starting the whole app. It is the same
/// [TaskSheet] the app uses, in the same see-through window as the "+" composer and the reminder drawer,
/// and it writes straight to the local replica. Accounts with the app lock on, or encrypted ones this
/// device has not unlocked, open the full app instead. The widget's top-right arrow still opens the full app.
class TaskSheetApp extends StatelessWidget {
  const TaskSheetApp({super.key});

  @override
  Widget build(BuildContext context) => const PopupShell(home: _TaskSheetHost());
}

class _TaskSheetHost extends StatefulWidget {
  const _TaskSheetHost();

  @override
  State<_TaskSheetHost> createState() => _TaskSheetHostState();
}

class _TaskSheetHostState extends State<_TaskSheetHost> {
  Repo? _repo;

  /// Bumped for every task shown, so a slower earlier one never closes the window under a newer tap.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ReminderService.markBackground();
    SystemBridge.listenTaskSheet(_onNewTask);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final id = await SystemBridge.taskSheetId();
      if (id == null) {
        await SystemBridge.closeTaskSheet();
        return;
      }
      await _show(id);
    });
  }

  /// Another row was tapped while this one is open: swap to it.
  void _onNewTask(String id) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    _show(id);
  }

  Future<void> _show(String taskId) async {
    final mine = ++_generation;
    var handedToApp = false;
    Repo? repo;
    try {
      // The app lock gates the interface with the fingerprint or device PIN, and this window has no such
      // gate (a task's notes are more than the widget shows). People who use it get the full app, which
      // asks first.
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(AppState.appLockPref) ?? false) {
        handedToApp = true;
        await SystemBridge.openTaskSheetInApp(taskId);
        return;
      }
      // An end-to-end encrypted account works here once the app has unlocked it on this device: the key
      // is kept in the platform keystore (restore() loads it), the local replica holds plaintext, and
      // the sync engine seals edits when the app next pushes them. Only a device that has never been
      // unlocked has no key, and the popup would show ciphertext, so that one asks the app, which asks
      // for the passphrase.
      await E2eeSession.instance.restore();
      if (E2eeSession.instance.enabled && !E2eeSession.instance.unlocked) {
        handedToApp = true;
        await SystemBridge.openTaskSheetInApp(taskId);
        return;
      }
      repo = _repo ??= await openHeadlessRepo();
      final task = (await repo.tasks()).where((t) => t.id == taskId && !t.isDeleted).firstOrNull;
      // Gone since the widget was drawn (deleted on another device, say): nothing to edit.
      if (task == null) return;
      final projects = await repo.projects();
      if (!mounted || mine != _generation) return;

      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => TaskSheet(task: task, repo: repo!, projects: projects),
      );
    } on Object catch (e) {
      await DebugLog.add('task sheet FAILED: $e', source: 'popup');
    } finally {
      // A newer tap owns the window now; otherwise the edits must reach the widget and the reminders
      // before the window goes.
      if (mine == _generation) {
        if (repo != null && !handedToApp) {
          try {
            await refreshTaskSurfaces(repo);
          } on Object catch (e) {
            await DebugLog.add('task sheet refresh FAILED: $e', source: 'popup');
          }
        }
        await SystemBridge.closeTaskSheet();
      }
    }
  }

  @override
  Widget build(BuildContext context) => const Scaffold(backgroundColor: Colors.transparent);
}
