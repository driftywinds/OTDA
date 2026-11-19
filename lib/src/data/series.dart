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
  ]) {
    if (raw[key] != null) fields[key] = raw[key];
  }
  fields['created_at'] = now;
  fields['recurrence'] = null; // a record is one occurrence, not a series
  fields['series_id'] = series.id;
  fields['occurrence_date'] = date;
  fields['completed_at'] = now;
  fields['skipped'] = false;
  if (raw['evening'] == true) fields['evening'] = true;
  return fields;
}

/// The next due date after finishing the occurrence in front of you, or null when
/// the series is over (`count` used up, or the next date is past `until`).
String? nextOccurrenceAfterCompletion(Task series, int finishedRecords, String today) {
  final raw = series.raw['recurrence']?.toString() ?? '';
  final parsed = rules.parseRule(raw);
  if (!parsed.ok) return null;
  final rule = parsed.rule!;

  final String next;
  if (rule.afterCompletion) {
    // "Every 3 days after completion" counts from the day it was done.
    next = rules.nextAfterCompletion(raw, today);
  } else {
    next = rules.nextOccurrence(raw, series.dueDate, today);
  }
  if (rule.count > 0 && finishedRecords + 1 >= rule.count) return null;
  final until = rule.until;
  if (until != null && next.compareTo(until) > 0) return null;
  return next;
}
