import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../quickadd/rule.dart' as rules;
import 'models.dart';

/// Series completion, ported from the web client's `recurring.ts`.
///
/// Ticking a repeating task does not complete the task: it writes one occurrence
/// record (a task with `series_id` and `occurrence_date`, no rule) and moves the
/// series to its next occurrence. Writing `completed_at` on the series itself is
/// what made a daily task vanish for good.
///
/// shortcut: the exceptions a record can carry (a skipped date, a moved
/// occurrence, a rotation's turn) are not read back yet, so a series advances one
/// occurrence at a time from its own due date. Add them with the records UI.

/// The occurrence in front of the person: the series' due date, or today.
String occurrenceDateOf(Task series, String today) => series.dueDate ?? today;

/// The deterministic id of the occurrence record for [date] (Go `sync.NameID`,
/// the web's `occurrenceId`): sha256 of `occurrence:<seriesId>:<date>` cut to a
/// version-8 UUID, so every client lands on the same row.
String occurrenceIdOf(String seriesId, String date) {
  final bytes = [...sha256.convert(utf8.encode('occurrence:$seriesId:$date')).bytes].sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// [day] moved by [days] calendar days.
String addDays(String day, int days) {
  final parsed = DateTime.tryParse(day);
  if (parsed == null) return day;
  final moved = DateTime.utc(parsed.year, parsed.month, parsed.day).add(Duration(days: days));
  return '${moved.year.toString().padLeft(4, '0')}-'
      '${moved.month.toString().padLeft(2, '0')}-'
      '${moved.day.toString().padLeft(2, '0')}';
}

/// `date` moved by as many calendar days as [from] is from [to].
String shiftDate(String date, String from, String to) {
  final d = DateTime.tryParse(date);
  final f = DateTime.tryParse(from);
  final t = DateTime.tryParse(to);
  if (d == null || f == null || t == null) return date;
  final moved = DateTime.utc(d.year, d.month, d.day).add(Duration(days: t.difference(f).inDays));
  return '${moved.year.toString().padLeft(4, '0')}-'
      '${moved.month.toString().padLeft(2, '0')}-'
      '${moved.day.toString().padLeft(2, '0')}';
}

/// The due date on another occurrence, keeping the time and zone it had.
Map<String, Object?> movedDue(Task series, String date) {
  final due = series.due;
  final time = due?['time']?.toString();
  final tz = due?['tz']?.toString();
  return {'date': date, 'time': ?time, 'tz': ?tz};
}

/// The series' dates on another occurrence: due moves to [next], and a deadline or
/// start moves by the same number of days. A `someday` start stays as it is.
Map<String, Object?> movedDates(Task series, String next, String today) {
  final from = occurrenceDateOf(series, today);
  final out = <String, Object?>{'due': movedDue(series, next)};
  for (final key in const ['deadline', 'start']) {
    final value = series.raw[key];
    if (value is Map && value['date'] != null) {
      out[key] = {...value.cast<String, Object?>(), 'date': shiftDate(value['date'].toString(), from, next)};
    } else if (value is String && value.isNotEmpty && value != 'someday') {
      out[key] = shiftDate(value, from, next);
    }
  }
  return out;
}

/// The record that stands for one finished occurrence: the series' fields on that
/// date, without the rule.
Map<String, Object?> occurrenceFields(Task series, String date, int now, String today) {
  final raw = series.raw;
  final fields = <String, Object?>{...movedDates(series, date, today)};
  for (final key in const [
    'title',
    'description',
    'project_id',
    'parent_id',
    'priority',
    'labels',
    'position',
    'estimate_minutes',
    'section_id',
    'energy',
  ]) {
    if (raw[key] != null) fields[key] = raw[key];
  }
  // A someday start is a value, not a date to move.
  if (raw['start'] == 'someday') fields['start'] = 'someday';
  fields['created_at'] = now;
  fields['recurrence'] = null; // a record is one occurrence, not a series
  fields['series_id'] = series.id;
  fields['occurrence_date'] = date;
  fields['completed_at'] = now;
  fields['skipped'] = false;
  if (raw['evening'] == true) fields['evening'] = true;
  return fields;
}

/// One finished (or skipped) occurrence of a series, as a real task row.
class SeriesRecord {
  const SeriesRecord(this.task, this.date, this.state);

  final Task task;
  final String date;

  /// `done`, `skipped` or `open`.
  final String state;
}

/// The live occurrence records of [seriesId].
List<SeriesRecord> recordsOf(String seriesId, Iterable<Task> tasks) {
  final out = <SeriesRecord>[];
  for (final task in tasks) {
    if (task.isDeleted || task.raw['series_id']?.toString() != seriesId) continue;
    final date = task.raw['occurrence_date']?.toString();
    if (date == null || date.isEmpty) continue;
    final state = !task.isCompleted ? 'open' : (task.raw['skipped'] == true ? 'skipped' : 'done');
    out.add(SeriesRecord(task, date, state));
  }
  return out;
}

/// The exception dates of a series: every date a record stands for.
Set<String> exceptionDatesOf(String seriesId, Iterable<Task> tasks) =>
    {for (final record in recordsOf(seriesId, tasks)) record.date};

/// What `for N times` has used, and which dates are exceptions.
class SeriesBudget {
  SeriesBudget({required this.taken, required this.done, required this.open, required this.except, required this.own});

  /// Occurrences used before the series' current one.
  final int taken;
  final int done;
  final int open;

  /// Every exception date, whatever the record's state.
  final Set<String> except;

  /// The dates of this series' own records.
  final Set<String> own;
}

/// The budget of a series, given every task on the device.
///
/// shortcut: series splits (one series continuing as another) are not modelled, so
/// a split made in the web app counts as an ordinary series here.
SeriesBudget seriesBudget(Task series, Iterable<Task> tasks, {String? exceptDate}) {
  var done = 0;
  var open = 0;
  final except = <String>{};
  final own = <String>{};
  for (final record in recordsOf(series.id, tasks)) {
    except.add(record.date);
    own.add(record.date);
    if (record.date == exceptDate) continue;
    if (record.state == 'done') {
      done++;
    } else if (record.state == 'open') {
      open++;
    }
  }
  return SeriesBudget(taken: done + open, done: done, open: open, except: except, own: own);
}

/// The next occurrence after finishing the one in front of you, or null when the
/// series is over (`count` used up, or past `until`). The web's
/// `followingOccurrence`.
String? followingOccurrence(String rule, String? due, String today, String completedOn, int taken) {
  final parsed = rules.parseRule(rule);
  if (!parsed.ok) return null;
  final r = parsed.rule!;
  final String next;
  if (r.afterCompletion) {
    next = rules.nextAfterCompletion(rule, completedOn);
  } else {
    next = rules.nextOccurrence(rule, due, today);
  }
  if (r.count > 0 && taken + 1 >= r.count) return null;
  final until = r.until;
  if (until != null && next.compareTo(until) > 0) return null;
  return next;
}

/// The next occurrence that is not an exception date.
String? nextFree(String rule, String? due, String today, String completedOn, int taken, Set<String> except) {
  var next = followingOccurrence(rule, due, today, completedOn, taken);
  for (var guard = 0; next != null && except.contains(next); guard++) {
    if (guard == 3700) return null;
    next = followingOccurrence(rule, next, today, rule.contains('after completion') ? next : today, taken);
  }
  return next;
}

/// The occurrence the series stands on for acting: its due date, or the next free
/// date after one another client already recorded. Null when the series is over.
String? currentOccurrence(Task series, List<Task> tasks, String today) {
  final rule = series.raw['recurrence']?.toString() ?? '';
  final parsed = rules.parseRule(rule);
  if (!parsed.ok) return null;
  final date = occurrenceDateOf(series, today);
  final budget = seriesBudget(series, tasks, exceptDate: date);
  final until = parsed.rule!.until;
  if (until != null && date.compareTo(until) > 0) return null;
  if (!budget.except.contains(date)) return date;
  return nextFree(rule, date, today, today, budget.taken - 1, budget.except);
}

/// The next occurrence a person would see after [today], honouring the records
/// other clients wrote: skipped dates and moved occurrences are stepped over.
String? nextOccurrenceAfter(Task series, List<Task> tasks, String today) {
  final rule = series.raw['recurrence']?.toString() ?? '';
  if (!rules.parseRule(rule).ok) return null;
  final budget = seriesBudget(series, tasks);
  var next = nextFree(rule, series.dueDate, today, today, budget.taken, budget.except);
  for (var guard = 0; next != null && next.compareTo(today) <= 0; guard++) {
    if (guard == 3700) return null;
    next = nextFree(rule, next, today, today, budget.taken, budget.except);
  }
  return next;
}
