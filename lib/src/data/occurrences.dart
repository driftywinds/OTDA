import '../quickadd/rule.dart' as rules;
import 'models.dart';

/// Every occurrence of [tasks] between [from] and [to] inclusive, as (day, task)
/// pairs.
///
/// A plain task appears once, on its due date. A repeating one appears on every
/// day it falls due — the calendar has to show a daily task on every day, even
/// though the task row stores a single `due`.
List<(String, Task)> occurrencesBetween(
  Iterable<Task> tasks,
  String from,
  String to, {
  int maxPerTask = 500,
}) {
  final out = <(String, Task)>[];
  for (final task in tasks) {
    if (task.isDeleted) continue;
    final due = task.dueDate;
    final rule = task.raw['recurrence']?.toString() ?? '';
    final parsed = rule.isEmpty ? null : rules.parseRule(rule);

    if (parsed == null || !parsed.ok) {
      // One-off (or a rule we cannot read): only its own due date can place it.
      if (due != null && due.compareTo(from) >= 0 && due.compareTo(to) <= 0) out.add((due, task));
      continue;
    }

    final until = parsed.rule?.until;
    var day = due ?? from;
    if (day.compareTo(from) < 0) {
      // Asked about the day before the window, so an occurrence that lands
      // exactly on `from` is kept rather than skipped.
      day = rules.nextOccurrence(rule, due, _previousDay(from));
    }

    for (var guard = 0; day.compareTo(to) <= 0 && guard < maxPerTask; guard++) {
      if (until != null && day.compareTo(until) > 0) break;
      if (day.compareTo(from) >= 0) out.add((day, task));
      final next = _advance(rule, due, day);
      if (next.isEmpty || next.compareTo(day) <= 0) break; // never spin
      day = next;
    }
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

/// The occurrence strictly after [day].
///
/// [rules.nextOccurrence] answers "the first occurrence on or after a day" for
/// some rule kinds and "strictly after" for others, so stepping a series needs
/// its own rule: whole-day and whole-week intervals just add their period (which
/// keeps the anchor), everything else asks the projection about the next day.
String _advance(String rule, String? due, String day) {
  final parsed = rules.parseRule(rule);
  if (!parsed.ok) return '';
  final r = parsed.rule!;
  if (r.kind == 'interval' && (r.unit == 'day' || r.unit == 'week')) {
    final size = r.unit == 'week' ? 7 * r.interval : r.interval;
    return _addDays(day, size);
  }
  return rules.nextOccurrence(rule, due, _nextDay(day));
}

String _shift(String day, int days) {
  final parsed = DateTime.tryParse(day);
  if (parsed == null) return day;
  final shifted = DateTime(parsed.year, parsed.month, parsed.day + days);
  return '${shifted.year.toString().padLeft(4, '0')}-'
      '${shifted.month.toString().padLeft(2, '0')}-'
      '${shifted.day.toString().padLeft(2, '0')}';
}

String _addDays(String day, int days) => _shift(day, days);

String _nextDay(String day) => _shift(day, 1);

/// The day before [day], in the calendar (no time zones involved).
String _previousDay(String day) => _shift(day, -1);

/// `day` shifted by whole months, clamped to the first of the month.
String firstOfMonth(String day, int monthDelta) {  final parsed = DateTime.tryParse(day) ?? DateTime.now();
  final shifted = DateTime(parsed.year, parsed.month + monthDelta, 1);
  return '${shifted.year.toString().padLeft(4, '0')}-'
      '${shifted.month.toString().padLeft(2, '0')}-01';
}

/// The last day of the month `day` is in, shifted by whole months.
String lastOfMonth(String day, int monthDelta) {
  final parsed = DateTime.tryParse(day) ?? DateTime.now();
  final shifted = DateTime(parsed.year, parsed.month + monthDelta + 1, 0);
  return '${shifted.year.toString().padLeft(4, '0')}-'
      '${shifted.month.toString().padLeft(2, '0')}-'
      '${shifted.day.toString().padLeft(2, '0')}';
}
