// The widget reads one JSON snapshot; this pins the grouping, the "more" count,
// the overdue flag and that a repeating task completed today shows its next day.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/widget/snapshot.dart';

Task task(String id, Map<String, Object?> raw) => Task(id, {'id': id, ...raw});

void main() {
  const today = '2026-11-19';

  test('sections are ordered and only shown when they have rows', () {
    final snapshot = buildWidgetSnapshot([
      task('a', {'title': 'Late', 'due': {'date': '2026-11-18'}}),
      task('b', {'title': 'Now', 'due': {'date': today}}),
      task('c', {'title': 'Next', 'due': {'date': '2026-11-20'}}),
      task('d', {'title': 'Soon', 'due': {'date': '2026-11-23'}}),
      task('e', {'title': 'Far', 'due': {'date': '2026-12-30'}}),
    ], const [], today: today);

    final labels = [
      for (final row in snapshot['rows'] as List)
        if ((row as Map)['t'] == 'section') row['label'],
    ];
    expect(labels, ['Overdue', 'Today', 'Tomorrow', 'This week', 'Later']);
  });

  test('an overdue row is flagged and a done one is not shown as open', () {
    final snapshot = buildWidgetSnapshot([
      task('a', {'title': 'Late', 'due': {'date': '2026-11-18'}}),
    ], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final row = rows.firstWhere((r) => r['t'] == 'task');
    expect(row['overdue'], isTrue);
    expect(row['day'], '2026-11-18');
  });

  test('a repeating task done today appears on its next day', () {
    final series = task('s', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });
    final snapshot = buildWidgetSnapshot([series], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final row = rows.firstWhere((r) => r['t'] == 'task');
    expect(row['day'], '2026-11-20');
    expect(row['title'], 'Post e paper');
  });

  test('the list is capped and the remainder is counted', () {
    final snapshot = buildWidgetSnapshot([
      for (var i = 0; i < 40; i++)
        task('t$i', {'title': 'T$i', 'due': {'date': '2026-11-20'}}),
    ], const [], today: today, limit: 10);
    final tasks = (snapshot['rows'] as List).where((r) => (r as Map)['t'] == 'task');
    expect(tasks, hasLength(10));
    expect(snapshot['more'], 30);
  });

  test('a project filter drops the rest', () {
    final snapshot = buildWidgetSnapshot([
      task('a', {'title': 'Mine', 'due': {'date': today}, 'project_id': 'p1'}),
      task('b', {'title': 'Other', 'due': {'date': today}, 'project_id': 'p2'}),
    ], [Project('p1', {'id': 'p1', 'name': 'Main'})], projectId: 'p1', today: today);
    final titles = [
      for (final row in snapshot['rows'] as List)
        if ((row as Map)['t'] == 'task') row['title'],
    ];
    expect(titles, ['Mine']);
  });

  test('a task added with no date still appears, under Later', () {
    final snapshot = buildWidgetSnapshot([
      task('n', {'title': 'Buy milk'}),
    ], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final section = rows.firstWhere((r) => r['t'] == 'section');
    final row = rows.firstWhere((r) => r['t'] == 'task');
    expect(section['label'], 'Later');
    expect(row['title'], 'Buy milk');
    expect(row['right'], '');
  });
}
