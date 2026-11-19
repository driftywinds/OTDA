import '../quickadd/rule.dart' as rules;
import 'models.dart';
import 'occurrences.dart';

/// The day a task should be listed under in Upcoming.
///
/// A plain task uses its due date when that is ahead, and leaves once it is
/// done. A recurring one is projected to its next occurrence, so a monthly task
/// whose stored due has passed still appears on the day it comes round again.
///
/// Completing a recurring task only finishes the occurrence in front of you,
/// not the series: it stays in Upcoming, on the first occurrence after the one
/// just done, and only leaves when the series itself has run out (`until`, or a
/// `count` that is used up).
String? upcomingDay(Task task, String today) {
  if (task.isDeleted) return null;

  final due = task.dueDate;
  final raw = task.raw['recurrence']?.toString() ?? '';
  final recurring = raw.isNotEmpty;

  // A one-off that is done is finished for good.
  if (task.isCompleted && !recurring) return null;

  if (!task.isCompleted && due != null && due.compareTo(today) > 0) return due;
  if (!recurring) return null;

  final parsed = rules.parseRule(raw);
  final until = parsed.rule?.until;

  // The occurrence that was just done is not coming up again; look strictly
  // after it. A task ticked off ahead of time was done for its stored due, so
  // the search starts after that day rather than after today.
  final after = task.isCompleted && due != null && due.compareTo(today) > 0 ? due : today;

  if (due == null) {
    final next = rules.nextOccurrence(raw, due, after);
    if (next.compareTo(after) <= 0) return null;
    if (until != null && next.compareTo(until) > 0) return null;
    return next;
  }

  final first = shiftDay(after, 1);
  final found = occurrencesBetween([task], first, lastOfMonth(first, 36), maxPerTask: 1);
  return found.isEmpty ? null : found.first.$1;
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
