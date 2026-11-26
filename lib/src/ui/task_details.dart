import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/recurrence.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// The details a task has set, one coloured chip each: date, time, repeat,
/// deadline, estimate and labels. [labelNames] maps label ids to their names.
List<Widget> taskDetailChips(
  Task task, {
  required String today,
  required ColorScheme scheme,
  Map<String, String> labelNames = const {},
}) {
  final date = task.dueDate;
  final days = date == null ? null : daysBetween(today, date);
  final time = task.dueTime;
  final rule = task.raw['recurrence']?.toString() ?? '';
  final deadline = task.deadline;
  final estimate = task.estimateMinutes;
  final names = [
    for (final id in task.labels)
      if (labelNames[id] != null) labelNames[id]!,
  ];
  return [
    if (date != null)
      DetailChip(
        icon: Icons.event_rounded,
        label: friendlyDate(date, today),
        color: days != null && days < 0 ? scheme.error : detailColor(DetailKind.date),
      ),
    if (time != null)
      DetailChip(icon: Icons.schedule_rounded, label: time, color: detailColor(DetailKind.time)),
    if (rule.isNotEmpty)
      DetailChip(
        icon: Icons.repeat_rounded,
        label: recurrenceLabelOf(rule),
        color: detailColor(DetailKind.repeat),
      ),
    if (deadline != null)
      DetailChip(
        icon: Icons.hourglass_top_rounded,
        label: 'Due by ${friendlyDate(deadline, today)}',
        color: detailColor(DetailKind.deadline),
      ),
    if (estimate != null)
      DetailChip(
        icon: Icons.timelapse_rounded,
        label: durationLabel(estimate),
        color: detailColor(DetailKind.estimate),
      ),
    if (names.isNotEmpty)
      DetailChip(
        icon: Icons.label_outline_rounded,
        label: names.join(', '),
        color: detailColor(DetailKind.labels),
      ),
  ];
}
