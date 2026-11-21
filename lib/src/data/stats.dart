import 'models.dart';
import '../quickadd/rule.dart' as rules;

/// Statistics computed on the device from the replica. Mirrors the parts of
/// `web/src/lib/stats.ts` this app can show: completions per day and week, by
/// project and by label, plus a streak per repeating task.
class StatsPeriodKind {
  static const thisWeek = 'this-week';
  static const lastWeek = 'last-week';
  static const thisMonth = 'this-month';
  static const thisQuarter = 'this-quarter';
  static const thisYear = 'this-year';

  static const all = [thisWeek, lastWeek, thisMonth, thisQuarter, thisYear];
}

class StatsPeriod {
  const StatsPeriod(this.kind, this.start, this.end);

  final String kind;
  final String start;
  final String end;

  List<String> get days => daysInRange(start, end);
}

class DayCount {
  const DayCount(this.date, this.count);
  final String date;
  final int count;
}

class NamedCount {
  const NamedCount(this.id, this.name, this.count);
  final String id;
  final String name;
  final int count;
}

class SeriesStreak {
  const SeriesStreak(this.series, this.count);
  final Task series;
  final int count;
}

class Stats {
  const Stats({
    required this.completed,
    required this.perDay,
    required this.perProject,
    required this.perLabel,
    required this.streaks,
  });

  final int completed;
  final List<DayCount> perDay;
  final List<NamedCount> perProject;
  final List<NamedCount> perLabel;
  final List<SeriesStreak> streaks;

  /// The busiest day in the period, for drawing the bars.
  int get busiest => perDay.fold(0, (max, day) => day.count > max ? day.count : max);
}

/// The calendar period a choice stands for, in the viewer's local days.
StatsPeriod periodFor(String kind, String today, {int weekStart = 1}) {
  final date = DateTime.parse(today);
  final week = startOfWeek(date, weekStart);
  String iso(DateTime d) => _iso(d);
  switch (kind) {
    case StatsPeriodKind.lastWeek:
      final start = week.subtract(const Duration(days: 7));
      return StatsPeriod(kind, iso(start), iso(week.subtract(const Duration(days: 1))));
    case StatsPeriodKind.thisMonth:
      return StatsPeriod(kind, iso(DateTime(date.year, date.month, 1)), today);
    case StatsPeriodKind.thisQuarter:
      final firstMonth = ((date.month - 1) ~/ 3) * 3 + 1;
      return StatsPeriod(kind, iso(DateTime(date.year, firstMonth, 1)), today);
    case StatsPeriodKind.thisYear:
      return StatsPeriod(kind, iso(DateTime(date.year, 1, 1)), today);
    default:
      return StatsPeriod(kind, iso(week), today);
  }
}

DateTime startOfWeek(DateTime date, int weekStart) {
  final shift = (date.weekday - weekStart + 7) % 7;
  return DateTime(date.year, date.month, date.day - shift);
}

/// [start]..[end] inclusive, `YYYY-MM-DD`.
List<String> daysInRange(String start, String end) {
  final first = DateTime.tryParse(start);
  final last = DateTime.tryParse(end);
  if (first == null || last == null || last.isBefore(first)) return const [];
  final out = <String>[];
  for (var day = DateTime.utc(first.year, first.month, first.day);
      !day.isAfter(DateTime.utc(last.year, last.month, last.day));
      day = day.add(const Duration(days: 1))) {
    out.add('${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}');
  }
  return out;
}

/// Every statistic the screen shows, from the rows already on the device.
Stats computeStats({
  required List<Task> tasks,
  required List<Project> projects,
  required List<Label> labels,
  required StatsPeriod period,
  required String today,
  int weekStart = 1,
}) {
  final counts = {for (final day in period.days) day: 0};
  final projectCounts = <String, int>{};
  final labelCounts = <String, int>{};
  var completed = 0;

  for (final task in tasks) {
    if (task.isDeleted || !task.isCompleted) continue;
    final day = task.completedAt == null ? null : _dayOf(task.completedAt!);
    if (day == null || !counts.containsKey(day)) continue;
    completed++;
    counts[day] = counts[day]! + 1;
    final project = task.projectId;
    projectCounts[project ?? ''] = (projectCounts[project ?? ''] ?? 0) + 1;
    for (final label in task.labels) {
      labelCounts[label] = (labelCounts[label] ?? 0) + 1;
    }
  }

  final projectNames = {for (final project in projects) project.id: project.name};
  final labelNames = {for (final label in labels) label.id: label.name};
  final byProject = [
    for (final entry in projectCounts.entries)
      NamedCount(
        entry.key,
        entry.key.isEmpty ? 'Inbox' : projectNames[entry.key] ?? 'Project',
        entry.value,
      ),
  ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  final byLabel = [
    for (final entry in labelCounts.entries)
      NamedCount(entry.key, labelNames[entry.key] ?? 'Label', entry.value),
  ]..sort((a, b) => b.count.compareTo(a.count));

  return Stats(
    completed: completed,
    perDay: [for (final entry in counts.entries) DayCount(entry.key, entry.value)],
    perProject: byProject,
    perLabel: byLabel,
    streaks: seriesStreaks(tasks, today),
  );
}

/// Current streak per repeating task: how many consecutive occurrence records
/// were completed without missing a scheduled gap. A skipped occurrence breaks
/// the streak (it is not a completion), and so does an overdue series.
List<SeriesStreak> seriesStreaks(List<Task> tasks, String today) {
  final records = <String, List<Task>>{};
  for (final task in tasks) {
    final series = task.raw['series_id']?.toString();
    if (series == null || series.isEmpty) continue;
    if (task.isDeleted || !task.isCompleted || task.raw['skipped'] == true) continue;
    final date = (task.raw['occurrence_date'] ?? task.dueDate)?.toString();
    if (date == null || date.isEmpty) continue;
    records.putIfAbsent(series, () => []).add(task);
  }
  final out = <SeriesStreak>[];
  for (final series in tasks) {
    if (series.isDeleted || (series.raw['recurrence']?.toString() ?? '').isEmpty) continue;
    final own = records[series.id];
    if (own == null || own.isEmpty) continue;
    final dates = [
      for (final task in own) (task.raw['occurrence_date'] ?? task.dueDate).toString(),
    ]..sort((a, b) => b.compareTo(a));
    final gap = _expectedGap(series.raw['recurrence']?.toString() ?? '');
    final latest = dates.first;
    if (dayDistance(latest, today) > gap) continue;
    var streak = 1;
    for (var i = 1; i < dates.length; i++) {
      final between = dayDistance(dates[i], dates[i - 1]);
      if (between <= 0 || between > gap) break;
      streak++;
    }
    out.add(SeriesStreak(series, streak));
  }
  out.sort((a, b) => b.count.compareTo(a.count));
  return out;
}

/// The largest gap between two occurrences of a rule, in days, used to decide
/// whether a streak is still alive. Conservative for months and years.
int _expectedGap(String text) {
  final parsed = rules.parseRule(text);
  if (!parsed.ok) return 1;
  final rule = parsed.rule!;
  final interval = rule.interval <= 0 ? 1 : rule.interval;
  switch (rule.kind) {
    case 'weekdays':
      return 7 * interval;
    case 'interval':
      return switch (rule.unit) {
        'week' => 7 * interval,
        'month' => 31 * interval,
        'year' => 366 * interval,
        _ => interval,
      };
    default:
      return 31 * interval;
  }
}

/// Days from [a] to [b], both `YYYY-MM-DD`; negative when b is earlier.
int dayDistance(String a, String b) {
  final first = DateTime.tryParse(a);
  final second = DateTime.tryParse(b);
  if (first == null || second == null) return 0;
  return DateTime.utc(second.year, second.month, second.day)
      .difference(DateTime.utc(first.year, first.month, first.day))
      .inDays;
}

String _dayOf(int millis) => _iso(DateTime.fromMillisecondsSinceEpoch(millis));

String _iso(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
