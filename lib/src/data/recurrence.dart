import '../quickadd/rule.dart' as rules;
import 'models.dart';
import 'series.dart';

/// The day a task should be listed under in Upcoming.
///
/// A one-off uses its due date when that is ahead and leaves once it is done. A
/// repeating task is projected to its next occurrence that is not an exception, so
/// a series whose stored due has passed - or whose occurrence another client
/// skipped - still appears on the day it actually comes round.
String? upcomingDay(Task task, List<Task> all, String today) {
  if (task.isDeleted) return null;

  final raw = task.raw['recurrence']?.toString() ?? '';
  final due = task.dueDate;

  if (raw.isEmpty) {
    if (task.isCompleted || due == null) return null;
    return due.compareTo(today) > 0 ? due : null;
  }

  if (!task.isCompleted && due != null && due.compareTo(today) > 0) return due;
  return nextOccurrenceAfter(task, all, today);
}

/// Whether the task repeats at all, for the task sheet and the row.
bool isRecurring(Task task) => (task.raw['recurrence']?.toString() ?? '').isNotEmpty;

/// The stored rule, for display: canonical where it parses, as stored otherwise.
String recurrenceLabel(Task task) {
  final raw = task.raw['recurrence']?.toString() ?? '';
  if (raw.isEmpty) return '';
  final parsed = rules.parseRule(raw);
  return parsed.ok ? (parsed.canonical ?? raw) : raw;
}
