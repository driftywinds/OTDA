// Port of web/src/lib/nlp/quickadd.test.ts (OpenTodo v1.5.0). The tests of the
// browser localStorage settings (load/save/round-trip/old key) and of the app-level
// priority names are left out: neither exists in this pure-Dart port. The pure
// settings functions are covered.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd/attributes.dart';
import 'package:otda/src/quickadd/parse.dart';
import 'package:otda/src/quickadd/quickadd.dart';
import 'package:otda/src/quickadd/settings.dart';
import 'package:otda/src/quickadd/types.dart';
import 'package:otda/src/quickadd/vocab/index.dart';

import 'support.dart';

const ParseContext ctx = ParseContext(
  today: '2026-10-09',
  now: '10:00',
  languages: ['en'],
  projects: [ProjectRef(id: 'w', name: 'Work')],
);

const List<LabelRef> labels = [
  LabelRef(id: 'l-call', name: 'Call', color: '#ef4444', position: 1),
  LabelRef(id: 'l-old', name: 'errand', deletedAt: 5),
  LabelRef(id: 'l-desk2', name: 'desk', position: 9),
  LabelRef(id: 'l-desk1', name: 'Desk', position: 2),
];

void main() {
  group('toTaskInput', () {
    ({List<String> created, List<LabelRef> labels, String Function(String) createLabel}) deps(
        [List<LabelRef> existing = labels]) {
      final created = <String>[];
      return (
        created: created,
        labels: existing,
        createLabel: (String name) {
          created.add(name);
          return 'new-$name';
        },
      );
    }

    test('carries only explicit attributes so view defaults fill the rest', () {
      final d = deps();
      expect(toTaskInput(parse('Buy milk', ctx), labels: d.labels, createLabel: d.createLabel), {'title': 'Buy milk'});
      expect(
        toTaskInput(parse('Write report tomorrow #work @call p2 +45m', ctx), labels: d.labels, createLabel: d.createLabel),
        {
          'title': 'Write report',
          'due': {'date': '2026-10-10'},
          'project_id': 'w',
          'labels': ['l-call'],
          'priority': 2,
          'estimate_minutes': 45,
        },
      );
      expect(d.created, isEmpty);
    });

    test('resolves @names to existing label ids ignoring case', () {
      final d = deps();
      expect(toTaskInput(parse('Ring @CALL @call', ctx), labels: d.labels, createLabel: d.createLabel)['labels'], ['l-call']);
      // Duplicate names from sync: first in sidebar order wins, on every device.
      expect(toTaskInput(parse('Tidy @DESK', ctx), labels: d.labels, createLabel: d.createLabel)['labels'], ['l-desk1']);
      expect(d.created, isEmpty);
    });

    test('creates a missing label once, ignoring deleted ones, and keeps typed order', () {
      final d = deps();
      final input = toTaskInput(parse('Shop @errand @call @Errand', ctx), labels: d.labels, createLabel: d.createLabel);
      expect(d.created, ['errand']);
      expect(input['labels'], ['new-errand', 'l-call']);
    });

    test('findLabel and labelNameKey follow the label store rules', () {
      expect(labelNameKey('  Call '), 'call');
      expect(findLabel('call', labels)?.id, 'l-call');
      expect(findLabel('errand', labels), isNull);
      expect(findLabel('', labels), isNull);
    });
  });

  group('chipAtCaret (Backspace highlight)', () {
    test('picks the last chip when it ends the line and the caret is at the end', () {
      const v = 'Buy milk tomorrow p2';
      final r = parse(v, ctx);
      expect(chipAtCaret(r.chips, v, v.length, v.length), 1);
      const spaced = 'Buy milk tomorrow p2  ';
      expect(chipAtCaret(parse(spaced, ctx).chips, spaced, spaced.length, spaced.length), 1);
    });

    test('does nothing when the caret is elsewhere, text is selected or the line ends in plain text', () {
      const v = 'Buy milk tomorrow p2';
      final r = parse(v, ctx);
      expect(chipAtCaret(r.chips, v, 3, 3), -1);
      expect(chipAtCaret(r.chips, v, 0, v.length), -1);
      const plain = 'Buy milk tomorrow please';
      expect(chipAtCaret(parse(plain, ctx).chips, plain, plain.length, plain.length), -1);
      expect(chipAtCaret(const [], 'x', 1, 1), -1);
    });

    test('treats a due chip whose time ends the line as the last chip', () {
      const v = 'Dentist tomorrow p1 at 3pm';
      final r = parse(v, ctx);
      final i = chipAtCaret(r.chips, v, v.length, v.length);
      expect(r.chips[i].kind, 'due');
    });
  });

  group('dismissal bookkeeping', () {
    test('Backspace twice: dismissing the highlighted chip keeps the text and drops the chip', () {
      const v = 'Buy milk tomorrow p2';
      final r = parse(v, ctx);
      final dismissed = dismissChip([], r.chips[chipAtCaret(r.chips, v, v.length, v.length)]);
      final after = parse(v, ParseContext(
        today: ctx.today,
        now: ctx.now,
        languages: ctx.languages,
        projects: ctx.projects,
        dismissed: dismissed,
      ));
      expect(after.priority, isNull);
      expect(after.title, 'Buy milk p2');
      expect(after.due, const Due('2026-10-10'));
    });

    test('dismissing a multi-span due chip records every span once', () {
      final r = parse('Call tomorrow #work at 9', ctx);
      final due = r.chips.firstWhere((c) => c.kind == 'due');
      final once = dismissChip([], due);
      expect(once, hasLength(2));
      expect(dismissChip(once, due), hasLength(2));
      final after = parse('Call tomorrow #work at 9', ParseContext(
        today: ctx.today,
        now: ctx.now,
        languages: ctx.languages,
        projects: ctx.projects,
        dismissed: once,
      ));
      expectMatch(after, {'title': 'Call tomorrow at 9', 'due': null, 'projectId': 'w'});
    });

    test('typing after a dismissed word keeps it dismissed (Review may report … with Ana)', () {
      var line = 'Review may report';
      var dismissed = dismissChip([], parse(line, ctx).chips[0]);
      for (final next in ['Review may report ', 'Review may report w', 'Review may report with Ana']) {
        dismissed = rebaseDismissed(line, next, dismissed);
        line = next;
        final parsed = parse(line, ParseContext(
          today: ctx.today,
          now: ctx.now,
          languages: ctx.languages,
          projects: ctx.projects,
          dismissed: dismissed,
        ));
        expect(parsed.chips.any((c) => c.kind == 'due'), isFalse);
      }
      final parsed = parse(line, ParseContext(
        today: ctx.today,
        now: ctx.now,
        languages: ctx.languages,
        projects: ctx.projects,
        dismissed: dismissed,
      ));
      expect(parsed.title, 'Review may report with Ana');
    });
  });

  group('quick-add settings (the pure part)', () {
    test('resolves languages from the override or the device', () {
      expect(resolveLanguages(defaultQuickAddSettings, ['de-AT', 'en']), ['de', 'en']);
      expect(resolveLanguages(const QuickAddSettings(languages: ['pt']), ['de']), ['pt', 'en']);
      expect(resolveLanguages(defaultQuickAddSettings, ['ko']), ['en']);
      // An explicit empty list means English only, not "follow the device".
      expect(resolveLanguages(const QuickAddSettings(languages: []), ['de']), ['en']);
    });

    test('resolves the numeric date order', () {
      const auto = defaultQuickAddSettings;
      expect(resolveDayMonthOrder(auto, ['en-US']), DayMonthOrder.md);
      expect(resolveDayMonthOrder(auto, ['en']), DayMonthOrder.md);
      expect(resolveDayMonthOrder(auto, ['en-GB']), DayMonthOrder.dm);
      expect(resolveDayMonthOrder(auto, ['de-DE', 'en-US']), DayMonthOrder.dm);
      expect(resolveDayMonthOrder(auto, ['ja', 'fr']), DayMonthOrder.dm);
      expect(resolveDayMonthOrder(auto, ['ja']), DayMonthOrder.md);
      expect(resolveDayMonthOrder(const QuickAddSettings(languages: ['it']), ['en-US']), DayMonthOrder.dm);
      expect(
        resolveDayMonthOrder(auto, ['en-US'], const {'date_format': 'day-month'}),
        DayMonthOrder.dm,
      );
    });

    test('formats estimates', () {
      expect([formatMinutes(45), formatMinutes(60), formatMinutes(90), formatMinutes(125)], ['45m', '1h', '1h30m', '2h5m']);
    });
  });

  group('deadline in the task input (OpenSpec deadlines 7.1)', () {
    test('passes the deadline through only when the line set one', () {
      const at = ParseContext(today: '2026-10-14', now: '10:00', languages: ['en']);
      expect(toTaskInput(parse('Report deadline friday', at)), {'title': 'Report', 'deadline': '2026-10-16'});
      expect(toTaskInput(parse('Report', at)), {'title': 'Report'});
    });
  });

  group('parseQuickAdd (the port entry point)', () {
    test('returns the title, the task fields and the preview chips', () {
      final r = parseQuickAdd(
        'Call Ana tomorrow at 9 #w',
        today: '2026-10-09',
        now: '10:00',
        projects: const [ProjectRef(id: 'w', name: 'Work')],
        labels: const [LabelRef(id: 'l-call', name: 'Call')],
      );
      expect(r.title, 'Call Ana');
      expect(r.fields, {
        'title': 'Call Ana',
        'due': {'date': '2026-10-10', 'time': '09:00'},
        'project_id': 'w',
      });
      expect([for (final c in r.chips) c.kind], ['due', 'project']);
      expect(r.chips.first.spans.map((s) => s.text), ['tomorrow', 'at 9']);
      expect(r.unmatched, isEmpty);
    });

    test('a language tag drives the vocabulary, English stays active', () {
      expect(
        parseQuickAdd('Zahnarzt morgen', today: '2026-10-09', now: '10:00', language: 'de').fields['due'],
        {'date': '2026-10-10'},
      );
      expect(parseQuickAdd('Zahnarzt morgen', today: '2026-10-09', now: '10:00').fields['due'], isNull);
    });

    test('chipLabel reads a chip in words', () {
      const ps = [ProjectRef(id: 'work', name: 'Work')];
      final r = parseQuickAdd('Buy milk tomorrow p2 #work', today: '2026-10-09', now: '10:00', projects: ps);
      expect([for (final c in r.chips) chipLabel(c, projects: ps)], ['2026-10-10', 'p2', '#Work']);
    });
  });
}
