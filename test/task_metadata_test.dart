import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/series.dart';

void main() {
  test('an occurrence record carries the metadata the series has', () {
    final series = Task('series-1', {
      'id': 'series-1',
      'title': 'Water plants',
      'due': {'date': '2026-11-21'},
      'deadline': '2026-11-25',
      'start': '2026-11-20',
      'recurrence': 'every day',
      'energy': 'deep',
      'labels': ['l1', 'l2'],
      'section_id': 'sec-1',
      'estimate_minutes': 30,
      'priority': 2,
    });

    final record = occurrenceFields(series, '2026-11-22', 5000, '2026-11-21');
    expect(record['deadline'], '2026-11-26');
    expect(record['start'], '2026-11-21');
    expect(record['energy'], 'deep');
    expect(record['labels'], ['l1', 'l2']);
    expect(record['section_id'], 'sec-1');
    expect(record['estimate_minutes'], 30);
    expect(record['due'], {'date': '2026-11-22'});
    expect(record['series_id'], 'series-1');
    expect(record['occurrence_date'], '2026-11-22');
  });

  test('a someday start stays someday on the record, and absent fields stay absent', () {
    final series = Task('series-2', {
      'id': 'series-2',
      'title': 'Think',
      'due': {'date': '2026-11-21'},
      'start': 'someday',
      'recurrence': 'every week',
    });

    final record = occurrenceFields(series, '2026-11-28', 5000, '2026-11-21');
    expect(record['start'], 'someday');
    expect(record.containsKey('deadline'), isFalse);
    expect(record.containsKey('energy'), isFalse);
    expect(record.containsKey('estimate_minutes'), isFalse);
  });
}
