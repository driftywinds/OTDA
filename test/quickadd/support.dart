// Helpers shared by the ported quick-add tests: the parse result as the maps the
// TypeScript tests compare (chips and unmatched included), so a test reads the same
// as its web counterpart.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd/parse.dart';
import 'package:otda/src/quickadd/reminders.dart';
import 'package:otda/src/quickadd/types.dart';

/// A chip's value as JSON-comparable data: [Due] and [ReminderPhrase] become maps.
Object? chipValueJson(Object? value) {
  if (value is Due) return value.toJson();
  if (value is ReminderPhrase) return value.toJson();
  return value;
}

Map<String, Object?> chipJson(Chip c) => {
      'kind': c.kind,
      'key': c.key,
      'spans': [
        for (final s in c.spans) {'start': s.start, 'end': s.end, 'text': s.text},
      ],
      'value': chipValueJson(c.value),
    };

Map<String, Object?> unmatchedJson(Unmatched m) => {
      'span': {'start': m.span.start, 'end': m.span.end, 'text': m.span.text},
      'reason': m.reason,
      if (m.count != null) 'count': m.count,
    };

/// The full parse result as a map, keyed and shaped like the TS `ParseResult`.
Map<String, Object?> shape(ParseResult r) => {
      'title': r.title,
      'due': r.due?.toJson(),
      'deadline': r.deadline,
      'start': r.start,
      'sector': r.sector,
      'evening': r.evening,
      'dayPart': r.dayPart,
      'projectId': r.projectId,
      'labels': r.labels,
      'priority': r.priority,
      'energy': r.energy,
      'estimateMinutes': r.estimateMinutes,
      'spentMinutes': r.spentMinutes,
      'recurrence': r.recurrence,
      'reminders': [for (final x in r.reminders) x.toJson()],
      'chips': [for (final c in r.chips) chipJson(c)],
      'unmatched': [for (final m in r.unmatched) unmatchedJson(m)],
    };

/// `expect(result).toMatchObject(expected)`: only the keys stated are compared.
void expectMatch(ParseResult r, Map<String, Object?> expected) {
  final actual = shape(r);
  for (final e in expected.entries) {
    expect(actual[e.key], e.value, reason: 'key "${e.key}"');
  }
}
