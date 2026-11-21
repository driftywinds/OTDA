import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/recurrence.dart';
import '../data/stats.dart';

/// Completion statistics computed from the replica: no network, no server
/// call, so it works offline and for any period the device holds.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String _period = StatsPeriodKind.thisWeek;
  String _weekStart = 'mon';
  List<Task> _tasks = const [];
  List<Project> _projects = const [];
  List<Label> _labels = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = widget.state.repo;
    if (repo == null) return;
    final tasks = await repo.tasks();
    final projects = await repo.allProjects();
    final labels = await repo.labels();
    final prefs = await repo.userPrefs();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _projects = projects;
      _labels = labels;
      _weekStart = prefs['week_start']?.toString() ?? 'mon';
      _loading = false;
    });
  }

  int get _weekStartNumber => switch (_weekStart) {
        'sun' => 7,
        'sat' => 6,
        _ => 1,
      };

  String get _today {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = periodFor(_period, _today, weekStart: _weekStartNumber);
    final stats = computeStats(
      tasks: _tasks,
      projects: _projects,
      labels: _labels,
      period: period,
      today: _today,
      weekStart: _weekStartNumber,
    );
    final buckets = _buckets(stats, period);
    final busiest = buckets.fold(0, (max, day) => day.count > max ? day.count : max);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistics'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final kind in StatsPeriodKind.all)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: ChoiceChip(
                      label: Text(_label(kind)),
                      selected: _period == kind,
                      onSelected: (_) => setState(() => _period = kind),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _Hero(stats: stats, period: period, buckets: buckets, busiest: busiest),
                  if (stats.perProject.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SectionTitle('Completed by project'),
                    for (final project in stats.perProject) _CountRow(project: project, max: stats.perProject.first.count),
                  ],
                  if (stats.perLabel.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SectionTitle('Completed by label'),
                    for (final label in stats.perLabel) _CountRow(project: label, max: stats.perLabel.first.count, label: true),
                  ],
                  const SizedBox(height: 20),
                  _SectionTitle('Streaks'),
                  if (stats.streaks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No repeating task has a streak yet.',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  else
                    for (final streak in stats.streaks.take(8))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.local_fire_department_rounded, color: theme.colorScheme.primary),
                        title: Text(streak.series.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(recurrenceLabel(streak.series)),
                        trailing: Text(
                          '${streak.count}',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                ],
              ),
            ),
    );
  }

  String _label(String kind) => switch (kind) {
        StatsPeriodKind.thisWeek => 'This week',
        StatsPeriodKind.lastWeek => 'Last week',
        StatsPeriodKind.thisMonth => 'This month',
        StatsPeriodKind.thisQuarter => 'This quarter',
        _ => 'This year',
      };

  /// Daily bars up to a month, then weekly, then monthly, so a year never draws
  /// 365 slivers.
  List<DayCount> _buckets(Stats stats, StatsPeriod period) {
    if (period.days.length <= 35) return stats.perDay;
    final byWeek = <String, int>{};
    final byMonth = <String, int>{};
    for (final day in stats.perDay) {
      final date = DateTime.parse(day.date);
      final week = startOfWeek(date, _weekStartNumber);
      final weekKey = _iso(week);
      byWeek[weekKey] = (byWeek[weekKey] ?? 0) + day.count;
      final monthKey = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
      byMonth[monthKey] = (byMonth[monthKey] ?? 0) + day.count;
    }
    if (period.days.length <= 120) {
      return [for (final entry in byWeek.entries) DayCount(entry.key, entry.value)];
    }
    return [for (final entry in byMonth.entries) DayCount(entry.key, entry.value)];
  }

  static String _iso(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.stats,
    required this.period,
    required this.buckets,
    required this.busiest,
  });

  final Stats stats;
  final StatsPeriod period;
  final List<DayCount> buckets;
  final int busiest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = period.days.length;
    final average = days == 0 ? 0.0 : stats.completed / days;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${stats.completed}',
                  style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, height: 1),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    stats.completed == 1 ? 'task completed' : 'tasks completed',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${average.toStringAsFixed(1)} per day · ${_range(period)}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 64,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final bucket in buckets)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: Tooltip(
                          message: '${bucket.date}: ${bucket.count}',
                          child: Container(
                            height: bucket.count == 0
                                ? 3
                                : 6 + (48 * bucket.count / (busiest == 0 ? 1 : busiest)),
                            decoration: BoxDecoration(
                              color: bucket.count == 0 ? scheme.surfaceContainerHighest : scheme.primary,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _range(StatsPeriod period) =>
      '${_short(DateTime.parse(period.start))} – ${_short(DateTime.parse(period.end))}';

  String _short(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]}';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.1,
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.project, required this.max, this.label = false});

  final NamedCount project;
  final int max;
  final bool label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (label) ...[
            Icon(Icons.label_outline_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text('${project.count}', style: theme.textTheme.labelLarge),
                  ],
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: max == 0 ? 0 : project.count / max,
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
