import 'package:timezone/timezone.dart' as tz;

import '../data/models.dart';
import '../data/occurrences.dart';

/// One reminder the OS should hold: a single occurrence of a task.
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.taskId,
    required this.day,
    required this.at,
    required this.title,
    required this.body,
  });

  /// Stable across re-plans: the same occurrence replaces the same alarm.
  final int id;
  final String taskId;
  final String day;
  final tz.TZDateTime at;
  final String title;
  final String body;

  String get payload => '$taskId|$day';
}

/// The reminder time for a task that has a date but no time.
const defaultReminderTime = '09:00';

/// 31-bit stable id of an occurrence (the blueprint's `hash31(taskId + day)`).
int reminderId(String taskId, String day) {
  var hash = 0;
  for (final unit in '$taskId|$day'.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash == 0 ? 1 : hash;
}

/// The reminders to arm: every open occurrence in [window] that still lies ahead.
///
/// Pure: no plugin, no clock, no repository. A task with the date but no time uses
/// [defaultTime], and the wall-clock time is built in [zone] so a 9:00 reminder
/// stays 9:00 across a daylight-saving change.
List<PlannedReminder> planReminders(
  Iterable<Task> tasks, {
  required DateTime now,
  required tz.Location zone,
  Duration window = const Duration(days: 3),
  int maxCount = 48,
  String defaultTime = defaultReminderTime,
  Map<String, String> projectNames = const {},
  Map<String, tz.TZDateTime> snoozedUntil = const {},
  Map<String, int> offsets = const {},
}) {
  final today = _iso(now);
  final to = _iso(now.add(window));
  // A snooze can outlive the day it was set on: "10 min" at 23:55 fires at 00:05, when the
  // occurrence's own day is already yesterday. Look back as far as the oldest snoozed day, or that
  // reminder is silently dropped and never fires.
  var from = today;
  final snoozedDays = <String>{};
  for (final entry in snoozedUntil.entries) {
    if (!entry.value.isAfter(now)) continue;
    final day = entry.key.substring(entry.key.lastIndexOf('|') + 1);
    snoozedDays.add(day);
    if (day.compareTo(from) < 0) from = day;
  }
  // A date a finished (done or skipped) record stands for is not coming up any more. Without this a
  // completed occurrence other than the series' current one was still armed.
  final finished = <String>{
    for (final task in tasks)
      if (!task.isDeleted && task.isCompleted && task.raw['series_id'] != null)
        '${task.raw['series_id']}|${task.raw['occurrence_date']}',
  };
  final candidates = tasks.where((task) =>
      !task.isDeleted &&
      !task.isCompleted &&
      task.raw['series_id'] == null && // a finished occurrence is history, not a reminder
      task.dueDate != null);

  final out = <PlannedReminder>[];
  for (final (day, task) in occurrencesBetween(candidates, from, to)) {
    final time = task.dueTime ?? defaultTime;
    final parts = time.split(':');
    final hour = int.tryParse(parts.first) ?? 9;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final date = DateTime.parse(day);
    // Days before today are only here for their snooze; an unsnoozed one is history.
    if (day.compareTo(today) < 0 && !snoozedDays.contains(day)) continue;

    if (finished.contains('${task.id}|$day')) continue;

    final snoozeKey = '${task.id}|$day';
    final base = tz.TZDateTime(zone, date.year, date.month, date.day, hour, minute);
    final at = snoozedUntil[snoozeKey] ??
        base.subtract(Duration(minutes: offsets[task.id] ?? 0));
    if (!at.isAfter(now)) continue;

    out.add(PlannedReminder(
      id: reminderId(task.id, day),
      taskId: task.id,
      day: day,
      at: at,
      title: task.title.isEmpty ? 'Task' : task.title,
      body: _body(task, day, today, time, projectNames),
    ));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.take(maxCount).toList();
}

/// `Project · Today 9:00` — the project when there is one, then the day and time.
String _body(Task task, String day, String today, String time, Map<String, String> projectNames) {
  final project = projectNames[task.projectId ?? ''];
  final when = day == today ? 'Today' : _shortDay(day);
  final clock = time;
  return [if (project != null && project.isNotEmpty) project, '$when $clock'].join(' · ');
}

String _shortDay(String day) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = DateTime.tryParse(day);
  if (date == null) return day;
  return '${date.day} ${months[date.month - 1]}';
}

String _iso(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
