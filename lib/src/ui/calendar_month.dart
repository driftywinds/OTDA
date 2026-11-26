import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import 'theme.dart';

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

/// A month grid, Monday first and always six rows so changing month keeps the
/// height. Reads only [Task.dueDate], [Task.isCompleted] and [Task.isDeleted].
class MonthCalendar extends StatefulWidget {
  const MonthCalendar({
    super.key,
    required this.tasks,
    required this.onDaySelected,
    this.initialMonth,
  });

  /// Every task the caller has; the widget itself filters to `dueDate`.
  final List<Task> tasks;

  /// Fired with the tapped cell's local midnight.
  final void Function(DateTime day) onDaySelected;

  /// Month to show first; the month of `DateTime.now()` when null.
  final DateTime? initialMonth;

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> with SingleTickerProviderStateMixin {
  static const double _cellHeight = 46;

  late DateTime _month;
  DateTime? _selected;
  late final AnimationController _slideController;
  Animation<Offset> _slide = const AlwaysStoppedAnimation(Offset.zero);

  @override
  void initState() {
    super.initState();
    final start = widget.initialMonth ?? DateTime.now();
    _month = DateTime(start.year, start.month);
    _slideController = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  static int _dayKey(DateTime day) => day.year * 10000 + day.month * 100 + day.day;

  void _animateTo(DateTime next, int direction) {
    if (next.year == _month.year && next.month == _month.month) return;
    setState(() {
      _month = next;
      _slide = Tween(
        begin: Offset(direction > 0 ? 0.08 : -0.08, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    });
    _slideController.forward(from: 0);
  }

  void _move(int months) {
    _animateTo(DateTime(_month.year, _month.month + months), months.sign);
  }

  void _showThisMonth() {
    final now = DateTime.now();
    final months = (now.year - _month.year) * 12 + now.month - _month.month;
    if (months == 0) return;
    _animateTo(DateTime(now.year, now.month), months.sign);
  }

  void _swipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 120) return;
    // A left swipe brings the next month in, a right swipe the previous one.
    _move(velocity < 0 ? 1 : -1);
  }

  void _tap(DateTime day) {
    setState(() => _selected = day);
    widget.onDaySelected(day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // One pass over the caller's tasks: how many land on each day, and how many
    // of those are still open.
    final total = <int, int>{};
    final open = <int, int>{};
    for (final task in widget.tasks) {
      if (task.isDeleted) continue;
      final due = DateTime.tryParse(task.dueDate ?? '');
      if (due == null) continue;
      final key = _dayKey(due);
      total[key] = (total[key] ?? 0) + 1;
      if (!task.isCompleted) open[key] = (open[key] ?? 0) + 1;
    }

    final first = DateTime(_month.year, _month.month);
    final start = DateTime(first.year, first.month, 1 - (first.weekday - 1));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _swipe,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _move(-1),
                tooltip: 'Previous month',
                style: IconButton.styleFrom(backgroundColor: scheme.field),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: TextButton(
                  onPressed: _showThisMonth,
                  child: Text(
                    '${_monthNames[_month.month - 1]} ${_month.year}',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _move(1),
                tooltip: 'Next month',
                style: IconButton.styleFrom(backgroundColor: scheme.field),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          SlideTransition(
            position: _slide,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    for (final label in _weekdays)
                      Expanded(
                        child: Center(
                          child: Text(
                            label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                for (var row = 0; row < 6; row++)
                  SizedBox(
                    height: _cellHeight,
                    child: Row(
                      children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(
                            child: _dayCell(
                              DateTime(start.year, start.month, start.day + row * 7 + col),
                              today,
                              total,
                              open,
                              theme,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayCell(
    DateTime day,
    DateTime today,
    Map<int, int> total,
    Map<int, int> open,
    ThemeData theme,
  ) {
    final scheme = theme.colorScheme;
    final key = _dayKey(day);
    final inMonth = day.year == _month.year && day.month == _month.month;
    final selected = _selected != null && _dayKey(_selected!) == key;
    final isToday = _dayKey(today) == key;
    final count = total[key] ?? 0;
    final pending = open[key] ?? 0;
    // Muted for the cells that belong to the neighbouring months.
    final fade = inMonth ? 1.0 : 0.45;
    final numberColor = selected
        ? scheme.onPrimary
        : (inMonth ? scheme.onSurface : scheme.onSurfaceVariant).withValues(alpha: fade);
    final markColor =
        (pending > 0 ? scheme.primary : scheme.outline).withValues(alpha: fade);

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: '${_monthNames[day.month - 1]} ${day.day}, ${day.year}'
          '${isToday ? ', today' : ''}',
      child: GestureDetector(
        key: ValueKey('day-${day.year}-${day.month}-${day.day}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _tap(day),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              key: selected
                  ? const Key('calendar-selected')
                  : (isToday ? const Key('calendar-today') : null),
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? scheme.primary
                    : (isToday ? scheme.primary.withValues(alpha: 0.1) : null),
                border: isToday && !selected
                    ? Border.all(color: scheme.primary, width: 1.4)
                    : null,
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                '${day.day}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: numberColor,
                  fontWeight: (pending > 0 || selected || isToday) ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            SizedBox(height: 12, child: _indicator(count, pending, markColor, theme)),
          ],
        ),
      ),
    );
  }

  /// Up to three dots, then the count itself, and `9+` once it stops being a
  /// number worth reading at this size.
  Widget _indicator(int count, int pending, Color color, ThemeData theme) {
    if (count == 0) return const SizedBox.shrink();
    if (count <= 3) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Icon(Icons.circle, size: 4, color: color),
            ),
        ],
      );
    }
    return Center(
      child: Text(
        count >= 9 ? '9+' : '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10,
          height: 1,
          color: color,
          fontWeight: pending > 0 ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
    );
  }
}
