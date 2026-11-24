import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../quickadd/rule.dart' as rules;
import 'format.dart';
import 'theme.dart';

/// What the repeat sheet changed. The caller writes these fields as ops, so the
/// sheet itself never talks to the network.
class RepeatSelection {
  const RepeatSelection({required this.rule, required this.due, required this.reminderMinutes});

  final String rule;
  final Map<String, Object?>? due;

  /// Minutes before the due time, or null for the task's normal reminder.
  final int? reminderMinutes;
}

const _reminderChoices = <int?, String>{
  null: 'Default',
  0: 'On time',
  5: '5 minutes before',
  10: '10 minutes before',
  30: '30 minutes before',
  60: '1 hour before',
  1440: '1 day before',
};

/// The repeat editor: one sheet for the time, the reminder, the rule and how the
/// series ends, the same four things the upstream date sheet groups together.
Future<RepeatSelection?> showRepeatSheet(
  BuildContext context, {
  required Task task,
  required String today,
  required Map<String, Object?>? due,
  required String recurrence,
  required int? reminderMinutes,
}) {
  return showModalBottomSheet<RepeatSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _RepeatSheet(
      task: task,
      today: today,
      due: due,
      recurrence: recurrence,
      reminderMinutes: reminderMinutes,
    ),
  );
}

class _RepeatSheet extends StatefulWidget {
  const _RepeatSheet({
    required this.task,
    required this.today,
    required this.due,
    required this.recurrence,
    required this.reminderMinutes,
  });

  final Task task;
  final String today;
  final Map<String, Object?>? due;
  final String recurrence;
  final int? reminderMinutes;

  @override
  State<_RepeatSheet> createState() => _RepeatSheetState();
}

class _RepeatSheetState extends State<_RepeatSheet> {
  late Map<String, Object?>? _due = widget.due == null ? null : {...widget.due!};
  late String _rule = widget.recurrence;
  late int? _reminderMinutes = widget.reminderMinutes;

  String? get _date => _due?['date']?.toString();
  String? get _time => _due?['time']?.toString();

  Future<void> _pickTime() async {
    final current = _time;
    final parts = (current ?? '09:00').split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 9,
        minute: parts.length > 1 ? int.tryParse(parts.last) ?? 0 : 0,
      ),
    );
    if (picked == null || !mounted) return;
    final time = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    final date = _date ?? _todayIso();
    setState(() => _due = {'date': date, 'time': time});
  }

  String _todayIso() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _clearTime() async {
    final date = _date;
    setState(() => _due = date == null ? null : {'date': date});
  }

  Future<void> _pickReminder() async {
    final selected = await showModalBottomSheet<int?>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in _reminderChoices.entries)
              ListTile(
                title: Text(entry.value),
                trailing: _reminderMinutes == entry.key ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(context).pop(entry.key ?? -1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    // `null` is both the value for "Default" and the sheet's dismissal result.
    // The list above sends -1 for Default so a dismissal stays a no-op.
    if (selected == null) return;
    setState(() => _reminderMinutes = selected == -1 ? null : selected);
  }

  Future<void> _pickRepeat() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _RepeatChoices(
        current: _rule,
        due: _date,
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == '__custom') {
      final rule = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => _CustomRepeatSheet(rule: _rule, due: _date),
      );
      if (!mounted || rule == null) return;
      setState(() => _rule = rule);
      return;
    }
    setState(() => _rule = choice);
  }

  Future<void> _pickEnd() async {
    if (_rule.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a repeat first.')),
      );
      return;
    }
    final parsed = rules.parseRule(_rule);
    final currentUntil = parsed.ok ? parsed.rule!.until : null;
    final currentCount = parsed.ok ? parsed.rule!.count : 0;
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.all_inclusive_rounded),
              title: const Text('Never'),
              trailing: currentUntil == null && currentCount == 0 ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop('never'),
            ),
            ListTile(
              leading: const Icon(Icons.event_rounded),
              title: const Text('On a date'),
              subtitle: currentUntil == null ? null : Text(friendlyDate(currentUntil, widget.today)),
              onTap: () => Navigator.of(context).pop('date'),
            ),
            ListTile(
              leading: const Icon(Icons.numbers_rounded),
              title: const Text('After a number of times'),
              subtitle: currentCount == 0 ? null : Text('$currentCount times'),
              onTap: () => Navigator.of(context).pop('count'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'never') {
      setState(() => _rule = repeatRuleEnding(_rule));
      return;
    }
    if (choice == 'date') {
      final now = DateTime.now();
      final initial = currentUntil != null ? DateTime.tryParse(currentUntil) ?? now : now;
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 20),
      );
      if (picked == null || !mounted) return;
      final date = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
      setState(() => _rule = repeatRuleEnding(_rule, until: date));
      return;
    }
    final controller = TextEditingController(text: currentCount == 0 ? '10' : '$currentCount');
    final count = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End after'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Number of times', suffixText: 'times'),
          onSubmitted: (value) => Navigator.of(context).pop(int.tryParse(value)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(int.tryParse(controller.text)),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || count == null || count < 1) return;
    setState(() => _rule = repeatRuleEnding(_rule, count: count));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
                Expanded(
                  child: Text(
                    'Repeat',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Save',
                  onPressed: () => Navigator.of(context).pop(
                    RepeatSelection(rule: _rule, due: _due, reminderMinutes: _reminderMinutes),
                  ),
                  icon: const Icon(Icons.check_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _SheetRow(
              icon: Icons.schedule_rounded,
              label: 'Time',
              value: _time ?? 'No time',
              onTap: _pickTime,
              onClear: _time == null ? null : _clearTime,
            ),
            _SheetRow(
              icon: Icons.alarm_rounded,
              label: 'Reminder',
              value: _reminderChoices[_reminderMinutes] ?? 'Default',
              onTap: _pickReminder,
            ),
            _SheetRow(
              icon: Icons.repeat_rounded,
              label: 'Repeat',
              value: _rule.isEmpty ? 'Never' : repeatSummary(_rule),
              onTap: _pickRepeat,
              onClear: _rule.isEmpty ? null : () => setState(() => _rule = ''),
            ),
            _SheetRow(
              icon: Icons.event_repeat_rounded,
              label: 'Repeat ends',
              value: repeatEndLabel(_rule, widget.today),
              onTap: _rule.isEmpty ? null : _pickEnd,
            ),
            const SizedBox(height: 8),
            Text(
              'The reminder is stored on this device. The repeat rule and due time sync with your account.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.onClear,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: scheme.field,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 17),
                    onPressed: onClear,
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RepeatChoices extends StatelessWidget {
  const _RepeatChoices({required this.current, required this.due});

  final String current;
  final String? due;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final fallback = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final weekday = _weekdayName(due ?? fallback);
    final choices = <String, String>{
      '': 'None',
      'every day': 'Daily',
      'every ${weekday.toLowerCase()}': 'Weekly ($weekday)',
      'every month': 'Monthly',
      'every year': 'Yearly',
      'every weekday': 'Every weekday',
    };
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in choices.entries)
            ListTile(
              title: Text(entry.value),
              trailing: current == entry.key ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop(entry.key),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Custom'),
            subtitle: current.isNotEmpty && !choices.containsKey(current) ? Text(repeatSummary(current)) : null,
            onTap: () => Navigator.of(context).pop('__custom'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _CustomRepeatSheet extends StatefulWidget {
  const _CustomRepeatSheet({required this.rule, required this.due});

  final String rule;
  final String? due;

  @override
  State<_CustomRepeatSheet> createState() => _CustomRepeatSheetState();
}

class _CustomRepeatSheetState extends State<_CustomRepeatSheet> {
  late int _interval;
  late String _unit;
  late Set<int> _days;
  late bool _afterCompletion;

  @override
  void initState() {
    super.initState();
    final parsed = rules.parseRule(widget.rule);
    final rule = parsed.ok ? parsed.rule! : null;
    _interval = rule?.interval ?? 1;
    _unit = rule != null && rule.kind == 'interval' ? rule.unit : 'week';
    _afterCompletion = rule?.afterCompletion ?? false;
    final due = widget.due == null ? DateTime.now() : DateTime.tryParse(widget.due!) ?? DateTime.now();
    _days = {due.weekday};
    if (rule != null && (rule.kind == 'weekday' || rule.kind == 'weekdays') && rule.days != 0) {
      _days = {
        for (var day = 1; day <= 7; day++)
          if (rule.days & (1 << day) != 0) day,
      };
    }
  }

  String get _preview => customRepeatRule(
        interval: _interval,
        unit: _unit,
        weekdays: _unit == 'week' ? _days : const {},
        afterCompletion: _afterCompletion,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final units = <String, String>{'day': 'Day', 'week': 'Week', 'month': 'Month', 'year': 'Year'};
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
                Expanded(
                  child: Text(
                    'Custom',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Save',
                  onPressed: () {
                    if (rules.parseRule(_preview).ok) Navigator.of(context).pop(_preview);
                  },
                  icon: const Icon(Icons.check_rounded),
                ),
              ],
            ),
            _SectionCard(
              children: [
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  title: const Text('Count from completion'),
                  subtitle: const Text('Next occurrence starts when you tick this one'),
                  value: _afterCompletion,
                  onChanged: _unit == 'week' && _days.isNotEmpty
                      ? null
                      : (value) => setState(() => _afterCompletion = value),
                ),
                Divider(height: 1, color: scheme.cardBorder),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                  child: Row(
                    children: [
                      const Text('Every'),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 58,
                        child: DropdownButton<int>(
                          value: _interval,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (var n = 1; n <= 30; n++) DropdownMenuItem(value: n, child: Text('$n')),
                          ],
                          onChanged: (value) => setState(() => _interval = value ?? 1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<String>(
                          value: _unit,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final entry in units.entries)
                              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                          ],
                          onChanged: (value) => setState(() => _unit = value ?? 'week'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_unit == 'week')
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var day = 1; day <= 7; day++)
                          FilterChip(
                            label: Text(_weekdayNameForNumber(day).substring(0, 3)),
                            selected: _days.contains(day),
                            onSelected: (selected) => setState(() {
                              if (selected) {
                                _days.add(day);
                              } else {
                                _days.remove(day);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _preview,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// The canonical display of a rule, or the stored text when it does not parse.
String repeatSummary(String rule) {
  final parsed = rules.parseRule(rule);
  return parsed.ok ? (parsed.canonical ?? rule) : rule;
}

/// `Never`, `Ends 27 Nov` or `After 10 times`.
String repeatEndLabel(String rule, String today) {
  final parsed = rules.parseRule(rule);
  if (!parsed.ok) return 'Never';
  final r = parsed.rule!;
  if (r.until != null) return 'Ends ${friendlyDate(r.until!, today)}';
  if (r.count > 0) return 'After ${r.count} times';
  return 'Never';
}

/// The same rule with an end date or count. Passing neither clears the end.
String repeatRuleEnding(String rule, {String? until, int count = 0}) {
  final parsed = rules.parseRule(rule);
  if (!parsed.ok) return rule;
  final r = parsed.rule!
    ..until = until
    ..count = count;
  return rules.canonicalOf(r);
}

/// Builds the stored rule for the custom screen. Weekdays are ISO 1–7.
String customRepeatRule({
  required int interval,
  required String unit,
  Set<int> weekdays = const {},
  bool afterCompletion = false,
}) {
  final n = interval < 1 ? 1 : interval;
  final every = n == 1 ? '' : '$n ';
  String rule;
  if (unit == 'week' && weekdays.isNotEmpty) {
    final names = (weekdays.toList()..sort()).map(_weekdayNameForNumber).map((d) => d.toLowerCase()).toList();
    if (n == 1 && names.length == 1) {
      rule = 'every ${names.single}';
    } else if (n == 1) {
      rule = 'every ${names.join(', ')}';
    } else {
      rule = 'every $n weeks on ${names.join(', ')}';
    }
  } else {
    rule = 'every $every$unit${n == 1 ? '' : 's'}';
  }
  if (afterCompletion && weekdays.isEmpty && (unit == 'day' || unit == 'week' || unit == 'month' || unit == 'year')) {
    rule += ' after completion';
  }
  return rules.canonicalRule(rule) ?? rule;
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String _weekdayName(String date) {
  final parsed = DateTime.tryParse(date);
  return _weekdayNameForNumber(parsed?.weekday ?? DateTime.now().weekday);
}

String _weekdayNameForNumber(int weekday) => _weekdays[(weekday - 1).clamp(0, 6)];
