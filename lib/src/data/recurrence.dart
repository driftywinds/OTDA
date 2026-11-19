import '../quickadd/rule.dart' as rules;
import 'models.dart';

/// The day a task should be listed under in Upcoming.
///
/// A plain task uses its due date when that is ahead. A recurring one is
/// projected to its next occurrence, so a monthly task whose stored due has
/// passed still appears on the day it comes round again — the reason a repeating
/// task used to be missing from Upcoming entirely.
String? upcomingDay(Task task, String today) {
  if (task.isCompleted || task.isDeleted) return null;

  final due = task.dueDate;
  if (due != null && due.compareTo(today) > 0) return due;

  final raw = task.raw['recurrence']?.toString() ?? '';
  if (raw.isEmpty) return null;

  final next = rules.nextOccurrence(raw, due, today);
  if (next.compareTo(today) <= 0) return null;

  // Respect `until`: an occurrence after the end of the series is not coming.
  final parsed = rules.parseRule(raw);
  final until = parsed.rule?.until;
  if (until != null && next.compareTo(until) > 0) return null;
  return next;
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
