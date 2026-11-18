// The shared quick-add vectors, the parity proof of the port: every case runs
// through `parse` and is compared with the value web/src/lib/nlp/vectors.test.ts
// compares (title, due, projectId, labels, priority, estimateMinutes,
// spentMinutes, recurrence, reminders, plus dayPart/evening, energy, sector and
// deadline when the case states them). The fixture is copied unchanged from
// web/src/lib/nlp/quickadd.vectors.json (OpenTodo v1.5.0).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd/attributes.dart';
import 'package:otda/src/quickadd/parse.dart';

void main() {
  final data = jsonDecode(File('test/quickadd/quickadd.vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (data['cases'] as List).cast<Map<String, dynamic>>();

  group('shared quick-add vectors (${cases.length} cases)', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final ctx = c['ctx'] as Map<String, dynamic>;
        final projects = [
          for (final p in ((ctx['projects'] as List?) ?? const []))
            ProjectRef(
              id: (p as Map<String, dynamic>)['id'] as String,
              name: p['name'] as String,
              parentId: p['parent_id'] as String?,
            ),
        ];
        final expected = (c['expect'] as Map).cast<String, Object?>();
        final r = parse(
          c['line'] as String,
          ParseContext(
            today: ctx['today'] as String,
            now: ctx['now'] as String?,
            languages: [for (final l in (ctx['languages'] as List).cast<String>()) l],
            projects: projects,
            dayParts: ctx['dayParts'] == true,
            energy: ctx['energy'] == true,
            sectors: ctx['sectors'] == true,
            weekStart: ((ctx['weekStart'] as num?) ?? 1).toInt(),
          ),
        );
        final actual = <String, Object?>{
          'title': r.title,
          'due': r.due?.toJson(),
          'projectId': r.projectId,
          'labels': r.labels,
          'priority': r.priority,
          'estimateMinutes': r.estimateMinutes,
          'spentMinutes': r.spentMinutes,
          'recurrence': r.recurrence,
          'reminders': [for (final x in r.reminders) x.toJson()],
        };
        // The part of the day, the energy, the sector and the deadline are compared
        // when the case states them, '' for none as the Go result has it.
        if (expected.containsKey('dayPart')) {
          actual['dayPart'] = r.dayPart;
          actual['evening'] = r.evening;
        }
        if (expected.containsKey('energy')) actual['energy'] = r.energy ?? '';
        if (expected.containsKey('sector')) actual['sector'] = r.sector ?? '';
        if (expected.containsKey('deadline')) actual['deadline'] = r.deadline ?? '';
        expect(actual, expected, reason: c['name'] as String);
      });
    }
  });
}
