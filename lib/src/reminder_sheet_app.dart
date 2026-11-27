import 'package:flutter/services.dart' show HapticFeedback;
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';

import 'data/models.dart';
import 'data/repo.dart';
import 'quick_add_app.dart' show PopupShell;
import 'reminders/debug_log.dart';
import 'reminders/planner.dart' show defaultReminderTime;
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
      final reminderTime = await ReminderService.instance.reminderTime();
      if (!mounted || mine != _generation) return;

      final choice = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        // The card draws its own rounded, floating shape.
        backgroundColor: Colors.transparent,
        elevation: 0,
        builder: (_) => ReminderSheet(task: task, day: day, project: project, reminderTime: reminderTime),
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

/// The drawer's content. Pops with `complete`, a snooze action id (see [snoozeTarget]), `open`, or null
/// when dismissed.
///
/// A floating card: the due day and project on top, the title, and the two actions pinned to the bottom
/// edge where a thumb rests. Snooze swaps the card's body for a list of fixed times, each showing when it
/// will wake the task, so nothing needs a second tap to understand.
class ReminderSheet extends StatefulWidget {
  const ReminderSheet({
    super.key,
    required this.task,
    required this.day,
    this.project,
    this.reminderTime = defaultReminderTime,
  });

  final Task task;

  /// The occurrence the reminder was for (`yyyy-MM-dd`), which may not be the task's own due date.
  final String day;
  final Project? project;

  /// The `HH:mm` "Tomorrow" and "Next week" land on.
  final String reminderTime;

  @override
  State<ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<ReminderSheet> {
  bool _choosingSnooze = false;
  String? _error;

  // ---- what the header says -------------------------------------------------

  String get _day => widget.day.isNotEmpty ? widget.day : (widget.task.dueDate ?? _isoOf(DateTime.now()));

  static String _isoOf(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  bool get _overdue {
    final due = DateTime.tryParse(_day);
    if (due == null) return false;
    final time = widget.task.dueTime;
    final parts = (time ?? '').split(':');
    final at = DateTime(
      due.year,
      due.month,
      due.day,
      int.tryParse(parts.first) ?? 23,
      parts.length > 1 ? int.tryParse(parts[1]) ?? 59 : 59,
    );
    return at.isBefore(DateTime.now());
  }

  String get _when {
    final today = _isoOf(DateTime.now());
    final day = friendlyDate(_day, today);
    final time = widget.task.dueTime;
    final parsed = time == null ? null : _parseClock(time);
    return parsed == null ? day : '$day, ${_clock(parsed)}';
  }

  static DateTime? _parseClock(String hhmm) {
    final parts = hhmm.split(':');
    final h = int.tryParse(parts.first);
    final m = parts.length > 1 ? int.tryParse(parts[1]) : 0;
    if (h == null || m == null) return null;
    return DateTime(2000, 1, 1, h, m);
  }

  static String _clock(DateTime t) => DateFormat.jm().format(t);

  Color? _projectColor() {
    final raw = widget.project?.color?.replaceFirst('#', '');
    if (raw == null || (raw.length != 6 && raw.length != 8)) return null;
    final value = int.tryParse(raw, radix: 16);
    if (value == null) return null;
    return Color(raw.length == 6 ? 0xFF000000 | value : value);
  }

  // ---- actions --------------------------------------------------------------

  void _finish(String choice) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(choice);
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2, now.month, now.day),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!at.isAfter(DateTime.now())) {
      setState(() => _error = 'Pick a time that has not passed yet.');
      return;
    }
    _finish('snooze_at:${at.millisecondsSinceEpoch}');
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final height = media.size.height;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Material(
          color: scheme.surfaceContainerHigh,
          elevation: 3,
          shadowColor: Colors.black,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height * 0.72),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                child: _choosingSnooze
                    ? _SnoozePane(
                        key: const ValueKey('snooze'),
                        reminderTime: widget.reminderTime,
                        error: _error,
                        onBack: () => setState(() {
                          _choosingSnooze = false;
                          _error = null;
                        }),
                        onClose: () => Navigator.of(context).pop(),
                        onChoose: _finish,
                        onCustom: _pickCustom,
                      )
                    : _mainPane(context, height),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _mainPane(BuildContext context, double screenHeight) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = widget.task.title.isEmpty ? 'Task' : widget.task.title;
    final note = (widget.task.raw['description']?.toString() ?? '').trim();
    final project = widget.project;
    final projectColor = _projectColor();
    final repeats = (widget.task.raw['recurrence']?.toString() ?? '').isNotEmpty;
    final dateColor = _overdue ? scheme.error : scheme.primary;

    return SizedBox(
      key: const ValueKey('main'),
      // Tall enough that the buttons sit low, where a thumb rests, whatever the title length.
      height: (screenHeight * 0.3).clamp(300.0, 420.0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 14,
                    runSpacing: 2,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_when, style: text.labelLarge?.copyWith(color: dateColor, fontWeight: FontWeight.w600)),
                          if (repeats) ...[
                            const SizedBox(width: 5),
                            Icon(Icons.repeat_rounded, size: 15, color: dateColor),
                          ],
                        ],
                      ),
                      if (project != null && project.name.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (projectColor != null)
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(color: projectColor, shape: BoxShape.circle),
                              )
                            else
                              Icon(Icons.inbox_rounded, size: 15, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(project.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                _HeaderButton(
                  tooltip: 'Open task',
                  icon: Icons.open_in_new_rounded,
                  onPressed: () => _finish('open'),
                ),
                _HeaderButton(
                  tooltip: 'Close',
                  icon: Icons.close_rounded,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // The title and note take the middle and scroll if long; the buttons below never move.
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.2)),
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(note,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Snooze',
                    icon: Icons.snooze_rounded,
                    background: scheme.surfaceContainerHighest,
                    foreground: scheme.onSurface,
                    onPressed: () => setState(() => _choosingSnooze = true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionButton(
                    label: 'Complete',
                    icon: Icons.check_rounded,
                    background: scheme.primary.withValues(alpha: 0.18),
                    foreground: scheme.primary,
                    onPressed: () => _finish('complete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 22),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
        color: background,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 56,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 19, color: foreground),
                const SizedBox(width: 8),
                Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: foreground, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );
}

/// The fixed-time snoozes. Each row says when it will wake the task, worked out by the same
/// [snoozeTarget] that applies it.
class _SnoozePane extends StatelessWidget {
  const _SnoozePane({
    super.key,
    required this.reminderTime,
    required this.error,
    required this.onBack,
    required this.onClose,
    required this.onChoose,
    required this.onCustom,
  });

  final String reminderTime;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final void Function(String action) onChoose;
  final VoidCallback onCustom;

  static const _choices = [
    ('snooze_10', '10 minutes', Icons.timer_outlined),
    ('snooze_30', '30 minutes', Icons.timer_outlined),
    ('snooze_60', '1 hour', Icons.schedule_rounded),
    ('snooze_180', '3 hours', Icons.schedule_rounded),
    ('snooze_evening', 'This evening', Icons.wb_twilight_rounded),
    ('snooze_tomorrow', 'Tomorrow', Icons.wb_sunny_outlined),
    ('snooze_nextweek', 'Next week', Icons.event_rounded),
  ];

  /// "6:00 PM" today, otherwise "Sat, 9:00 AM" or "Mon 30 Nov, 9:00 AM".
  static String _label(DateTime at, DateTime now) {
    final clock = DateFormat.jm().format(at);
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(at.year, at.month, at.day).difference(today).inDays;
    if (days == 0) return clock;
    if (days < 7) return '${DateFormat.E().format(at)}, $clock';
    return '${DateFormat('E d MMM').format(at)}, $clock';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final rows = <Widget>[];
    for (final (action, label, icon) in _choices) {
      final at = snoozeTarget(action, now, reminderTime);
      if (at == null) continue; // an evening that has already begun
      rows.add(_SnoozeRow(icon: icon, label: label, trailing: _label(at, now), onTap: () => onChoose(action)));
    }
    rows.add(_SnoozeRow(
      icon: Icons.edit_calendar_rounded,
      label: 'Pick date & time',
      trailing: null,
      onTap: onCustom,
    ));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              _HeaderButton(tooltip: 'Back', icon: Icons.arrow_back_rounded, onPressed: onBack),
              const SizedBox(width: 4),
              Expanded(child: Text('Snooze until', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
              _HeaderButton(tooltip: 'Close', icon: Icons.close_rounded, onPressed: onClose),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            children: rows,
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: Text(error!, style: text.bodySmall?.copyWith(color: scheme.error)),
          ),
      ],
    );
  }
}

class _SnoozeRow extends StatelessWidget {
  const _SnoozeRow({required this.icon, required this.label, required this.trailing, required this.onTap});

  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 21, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: text.bodyLarge)),
            if (trailing != null)
              Text(trailing!, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))
            else
              Icon(Icons.chevron_right_rounded, size: 22, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
