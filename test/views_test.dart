// Parity test for the view rules against the fixtures the web app and the Go
// server both read. If a rule here drifts, these cases fail.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/views.dart';

Map<String, Object?> _task(Map raw) => raw.cast<String, Object?>();

void main() {
  group('inbox.vectors.json', () {
    final cases = jsonDecode(File('test/fixtures/inbox.vectors.json').readAsStringSync()) as List;

    test('every Inbox case matches', () {
      var failures = 0;
      for (final entry in cases) {
        final map = entry as Map;
        final task = _task(map['task'] as Map);
        final parents = [
          for (final p in (map['parents'] as List?) ?? const []) _task(p as Map),
        ];
        final expected = map['inbox'] == true;
        final actual = inInbox(task, parents: parents);
        if (actual != expected) {
          failures++;
          stderr.writeln('  FAIL ${map['name']}: expected $expected, got $actual');
        }
      }
      expect(failures, 0, reason: '$failures of ${cases.length} inbox cases disagree');
      expect(cases.length, greaterThan(20));
    });
  });

  group('views.vectors.json', () {
    final cases = jsonDecode(File('test/fixtures/views.vectors.json').readAsStringSync()) as List;

    test('every Someday and Anytime case matches', () {
      var failures = 0;
      for (final entry in cases) {
        final map = entry as Map;
        final task = _task(map['task'] as Map);
        final someday = inSomedayView(task);
        final anytime = inAnytime(task, '2026-10-20');
        if (someday != (map['someday'] == true) || anytime != (map['anytime'] == true)) {
          failures++;
          stderr.writeln('  FAIL ${map['name']}: someday=$someday anytime=$anytime');
        }
      }
      expect(failures, 0, reason: '$failures of ${cases.length} view cases disagree');
    });
  });

  group('Today', () {
    const today = '2026-10-20';
    Map<String, Object?> task(Map<String, Object?> fields) => {'completed_at': null, ...fields};

    test('due today or earlier', () {
      expect(inToday(task({'due': {'date': '2026-10-20'}}), today), isTrue);
      expect(inToday(task({'due': {'date': '2026-10-01'}}), today), isTrue);
      expect(inToday(task({'due': {'date': '2026-10-21'}}), today), isFalse);
    });

    test('a passed deadline counts, a future one does not', () {
      expect(inToday(task({'deadline': today}), today), isTrue);
      expect(inToday(task({'deadline': '2026-12-01'}), today), isFalse);
    });

    test('a start date that has come counts, a future one defers', () {
      expect(inToday(task({'start': '2026-10-01'}), today), isTrue);
      expect(inToday(task({'start': '2026-12-01'}), today), isFalse);
    });

    test('a hard date wins over Someday', () {
      expect(inToday(task({'start': 'someday', 'due': {'date': '2026-10-01'}}), today), isTrue);
    });

    test('completed never counts', () {
      expect(inToday(task({'due': {'date': '2026-10-01'}, 'completed_at': 1}), today), isFalse);
    });
  });

  group('Inbox with parents', () {
    test('a subtask follows a placed parent out of the Inbox', () {
      final byId = <String, Map<String, Object?>>{
        'parent': {'id': 'parent', 'project_id': 'p1'},
      };
      final child = <String, Object?>{'id': 'child', 'parent_id': 'parent'};
      expect(inInboxOf(child, byId), isFalse);
    });

    test('an unknown parent does not place the task', () {
      final child = <String, Object?>{'id': 'child', 'parent_id': 'gone'};
      expect(inInboxOf(child, {}), isTrue);
    });
  });
}
