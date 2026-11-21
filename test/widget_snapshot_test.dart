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

  test('a repeating task due today is listed today, not projected away', () {
    final series = task('s', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
    });
    final snapshot = buildWidgetSnapshot([series], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final section = rows.firstWhere((r) => r['t'] == 'section');
    final row = rows.firstWhere((r) => r['t'] == 'task');
    expect(section['label'], 'Today');
    expect(row['day'], today);
    expect(row['title'], 'Post e paper');
  });

  test('a repeating task finished today shows its next occurrence', () {
    // Completed without a record (an older client): the rule still projects ahead.
    final series = task('s2', {
      'title': 'Post e paper',
      'due': {'date': today},
      'recurrence': 'every day',
      'completed_at': 1,
    });
    final snapshot = buildWidgetSnapshot([series], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final row = rows.firstWhere((r) => r['t'] == 'task');
    expect(row['day'], '2026-11-20');
  });

  test('an overdue repeating task stays overdue rather than jumping ahead', () {
    final series = task('s3', {
      'title': 'Post e paper',
      'due': {'date': '2026-11-18'},
      'recurrence': 'every day',
    });
    final snapshot = buildWidgetSnapshot([series], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final section = rows.firstWhere((r) => r['t'] == 'section');
    final row = rows.firstWhere((r) => r['t'] == 'task');
    expect(section['label'], 'Overdue');
    expect(row['overdue'], isTrue);
  });

  test('a plain task due today lands in Today', () {
    final snapshot = buildWidgetSnapshot([
      task('p', {'title': 'File receipts', 'due': {'date': today}}),
    ], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    expect(rows.firstWhere((r) => r['t'] == 'section')['label'], 'Today');
  });

  test('today’s done tasks come first, above Today, including a series occurrence', () {
    final doneAt = DateTime(2026, 11, 19, 10, 30).millisecondsSinceEpoch;
    final snapshot = buildWidgetSnapshot([
      task('open', {'title': 'Still open', 'due': {'date': today}}),
      task('done', {'title': 'Finished', 'due': {'date': '2026-11-18'}, 'completed_at': doneAt}),
      task('record', {
        'title': 'Post e paper',
        'series_id': 's',
        'occurrence_date': today,
        'due': {'date': today},
        'completed_at': doneAt + 1,
      }),
    ], const [], today: today);

    final rows = (snapshot['rows'] as List).cast<Map>();
    final labels = [for (final row in rows) if (row['t'] == 'section') row['label']];
    expect(labels, ['Done today', 'Today']);
    final tasks = [for (final row in rows) if (row['t'] == 'task') row];
    expect(tasks.map((row) => row['title']), ['Post e paper', 'Finished', 'Still open']);
    expect(tasks[0]['done'], isTrue);
    expect(tasks[1]['done'], isTrue);
    expect(tasks[2]['done'], isFalse);
  });

  test('a done task is not also listed under its old Overdue section', () {
    final snapshot = buildWidgetSnapshot([
      task('done', {
        'title': 'Late but done',
        'due': {'date': '2026-11-18'},
        'completed_at': DateTime(2026, 11, 19, 9, 0).millisecondsSinceEpoch,
      }),
    ], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    expect(rows.where((row) => row['t'] == 'section').map((row) => row['label']), ['Done today']);
    expect(rows.where((row) => row['t'] == 'task'), hasLength(1));
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

  test('a task added with no date still appears, under Anytime', () {
    final snapshot = buildWidgetSnapshot([
      task('n', {'title': 'Buy milk'}),
      task('d', {'title': 'Due today', 'due': {'date': today}}),
    ], const [], today: today);
    final rows = (snapshot['rows'] as List).cast<Map>();
    final labels = [for (final r in rows) if (r['t'] == 'section') r['label']];
    expect(labels, ['Today', 'Anytime']);
    final row = rows.last;
    expect(row['title'], 'Buy milk');
    expect(row['right'], '');
  });
}
