import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';

import 'data/models.dart';
import 'data/repo.dart';
import 'quick_add_app.dart' show PopupShell;
import 'reminders/debug_log.dart';
import 'reminders/service.dart';
import 'system_bridge.dart';
import 'ui/format.dart';

/// The drawer a tap on a reminder notification opens, like TickTick's: a see-through window over
/// whatever app is in front, with the task and two big buttons (Snooze, Complete) at the bottom, where
/// a thumb reaches. The notification's own Complete / Snooze buttons are unchanged and still run
/// without opening anything. A tap does not clear the notification: it stays, and opens this drawer
/// again on every tap, until the task is completed or snoozed from here or from its buttons.
///
/// It opens the replica without the main app, does what was chosen through [applyReminderAction] (the
/// same code the notification buttons use), refreshes the widget, re-arms reminders and closes itself.
class ReminderSheetApp extends StatelessWidget {
  const ReminderSheetApp({super.key});

  @override
  Widget build(BuildContext context) => const PopupShell(home: _ReminderHost());
}

class _ReminderHost extends StatefulWidget {
  const _ReminderHost();

  @override
  State<_ReminderHost> createState() => _ReminderHostState();
}

class _ReminderHostState extends State<_ReminderHost> {
  Repo? _repo;

  /// Bumped for every reminder shown, so a slower earlier one never closes the window under a newer tap.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ReminderService.markBackground();
    SystemBridge.listenReminder(_onNewPayload);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final payload = await SystemBridge.reminderPayload();
      if (payload == null) {
        await SystemBridge.closeReminder();
        return;
      }
      await _show(payload);
    });
  }

  /// Another reminder was tapped while this one is open: swap to it.
  void _onNewPayload(String payload) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    _show(payload);
  }

  Future<void> _show(String payload) async {
    final mine = ++_generation;
    try {
      final parts = payload.split('|');
      final taskId = parts.first;
      final day = parts.length > 1 ? parts[1] : '';
      final repo = _repo ??= await openHeadlessRepo();
      final tasks = await repo.tasks();
      final task = tasks.where((t) => t.id == taskId).firstOrNull;
      // Gone, or already done for this occurrence (ticked on the widget, say): nothing to act on, and
      // the notification, which a tap no longer clears, should not keep standing there.
      if (!reminderStillOpen(tasks, task, day)) {
        await ReminderService.instance.dismiss(taskId, day);
        return;
      }
      if (task == null) return;
      final project = (await repo.projects()).where((p) => p.id == task.projectId).firstOrNull;
      if (!mounted || mine != _generation) return;

      final choice = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ReminderSheet(task: task, day: day, projectName: project?.name),
      );
      // A newer tap replaced this sheet: it owns the window now.
      if (mine != _generation) return;
      // Closed without choosing: the notification stays, and tapping it opens the drawer again.
      if (choice == null) return;
      if (choice == 'open') {
        await SystemBridge.openTaskInApp(taskId, day);
        return;
      }
      final changed = await applyReminderAction(repo, choice, taskId, day);
      // Completed or snoozed (or found already done): the reminder is dealt with, so it leaves the shade.
      await ReminderService.instance.dismiss(taskId, day);
      if (changed) {
        await DebugLog.add('reminder sheet: $choice $taskId', source: 'popup');
        // The widget goes first: it must never wait for the reminders.
        await pushWidgetsFromRepo(repo);
        await ReminderService.instance.rearmFrom(repo);
      }
    } on Object catch (e) {
      await DebugLog.add('reminder sheet FAILED: $e', source: 'popup');
    } finally {
      if (mine == _generation) await SystemBridge.closeReminder();
    }
  }

  @override
  Widget build(BuildContext context) => const Scaffold(backgroundColor: Colors.transparent);
}

/// The drawer's content. Pops with `complete`, a snooze action id, `open`, or null when dismissed.
class ReminderSheet extends StatefulWidget {
  const ReminderSheet({super.key, required this.task, required this.day, this.projectName});

  final Task task;

  /// The occurrence the reminder was for (`yyyy-MM-dd`), which may not be the task's own due date.
  final String day;
  final String? projectName;

  @override
  State<ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<ReminderSheet> {
  bool _choosingSnooze = false;

  String get _when {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    final day = widget.day.isNotEmpty ? widget.day : (widget.task.dueDate ?? today);
    final time = widget.task.dueTime;
    return time == null || time.isEmpty ? friendlyDate(day, today) : '${friendlyDate(day, today)}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = widget.task.title.isEmpty ? 'Task' : widget.task.title;
    final project = widget.projectName;
    final height = MediaQuery.sizeOf(context).height;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 16),
        child: ConstrainedBox(
          // Tall enough that the buttons sit low, in reach of a thumb, however short the title is.
          constraints: BoxConstraints(minHeight: height * 0.3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(_when,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(color: scheme.primary)),
                  ),
                  if (project != null && project.isNotEmpty) ...[
                    const SizedBox(width: 14),
                    Icon(Icons.inbox_outlined, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(project,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    tooltip: 'Open task',
                    onPressed: () => Navigator.of(context).pop('open'),
                    icon: const Icon(Icons.open_in_new),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(title, style: text.titleLarge, maxLines: 4, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: _choosingSnooze ? _snoozeChoices(context) : _mainButtons(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mainButtons(BuildContext context) {
    const big = Size.fromHeight(56);
    return Row(
      key: const ValueKey('main'),
      children: [
        Expanded(
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(minimumSize: big),
            onPressed: () => setState(() => _choosingSnooze = true),
            child: const Text('Snooze'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: big),
            onPressed: () => Navigator.of(context).pop('complete'),
            child: const Text('Complete'),
          ),
        ),
      ],
    );
  }

  Widget _snoozeChoices(BuildContext context) {
    const big = Size.fromHeight(56);
    Widget choice(String label, String action) => Expanded(
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(minimumSize: big, padding: const EdgeInsets.symmetric(horizontal: 4)),
            onPressed: () => Navigator.of(context).pop(action),
            child: Text(label, maxLines: 1),
          ),
        );
    return Column(
      key: const ValueKey('snooze'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            choice('10 min', 'snooze_10'),
            const SizedBox(width: 8),
            choice('1 hour', 'snooze_60'),
            const SizedBox(width: 8),
            choice('Tomorrow', 'snooze_tomorrow'),
          ],
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => setState(() => _choosingSnooze = false),
          child: const Text('Back'),
        ),
      ],
    );
  }
}
