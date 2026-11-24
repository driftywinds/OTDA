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

/// The rule a row belongs to. An occurrence record has no `recurrence` of its
/// own by design (`occurrenceFields` writes null: one record is not a series),
/// so a finished occurrence resolves the rule from its `series_id`.
String recurrenceFor(Task task, Iterable<Task> all) {
  final own = task.raw['recurrence']?.toString() ?? '';
  if (own.isNotEmpty) return own;
  final seriesId = task.raw['series_id']?.toString();
  if (seriesId == null || seriesId.isEmpty) return '';
  for (final candidate in all) {
    if (candidate.id == seriesId) {
      return candidate.raw['recurrence']?.toString() ?? '';
    }
  }
  return '';
}

/// The canonical display of a rule string, for a row whose rule came from the
/// series rather than from the row itself.
String recurrenceLabelOf(String rule) {
  if (rule.isEmpty) return '';
  final parsed = rules.parseRule(rule);
  return parsed.ok ? (parsed.canonical ?? rule) : rule;
}
