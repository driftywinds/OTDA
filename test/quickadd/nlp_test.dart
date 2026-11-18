// Port of web/src/lib/nlp/nlp.test.ts (OpenTodo v1.5.0). Every scenario is kept;
// the only omissions are the web-only helpers (browser storage, i18n) and the
// `logicalToday` day-boundary call, noted where it would have been.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd/attributes.dart';
import 'package:otda/src/quickadd/dates.dart';
import 'package:otda/src/quickadd/parse.dart';
import 'package:otda/src/quickadd/tokenize.dart';
import 'package:otda/src/quickadd/types.dart';
import 'package:otda/src/quickadd/vocab/index.dart';

import 'support.dart';

// Friday 9 October 2026, 10:00 local: the reference date used by the spec scenarios.
const String todayIso = '2026-10-09';
const String nowHhmm = '10:00';

const List<ProjectRef> projects = [
  ProjectRef(id: 'p-work', name: 'Work'),
  ProjectRef(id: 'p-home', name: 'Home'),
  ProjectRef(id: 'p-homework', name: 'Homework'),
  ProjectRef(id: 'p-travel', name: 'Travel'),
  ProjectRef(id: 'p-old', name: 'Oldies', archived: true),
  ProjectRef(id: 'p-gone', name: 'Garden', deletedAt: 5),
];

ParseContext ctx({
  String today = todayIso,
  String? now = nowHhmm,
  List<String> languages = const ['en'],
  List<ProjectRef> projects = projects,
  List<Span> dismissed = const [],
  DayMonthOrder? dayMonthOrder,
  int weekStart = 1,
  bool dayParts = false,
  bool energy = false,
  bool sectors = false,
}) =>
    ParseContext(
      today: today,
      now: now,
      languages: languages,
      projects: projects,
      dismissed: dismissed,
      dayMonthOrder: dayMonthOrder,
      weekStart: weekStart,
      dayParts: dayParts,
      energy: energy,
      sectors: sectors,
    );

/// Parse one phrase alone and return its due value.
({Due? due, String title}) dueOf(
  String phrase, {
  List<String> languages = const ['en'],
  String today = todayIso,
  String? now = nowHhmm,
  DayMonthOrder? dayMonthOrder,
}) {
  final r = parse(phrase, ctx(languages: languages, today: today, now: now, dayMonthOrder: dayMonthOrder));
  return (due: r.due, title: r.title);
}

void main() {
  group('tokenize', () {
    test('splits on whitespace and reports character spans', () {
      final result = tokenize('  Buy   milk\ttomorrow ');
      expect([for (final t in result.tokens) [t.text, t.start, t.end]], [
        ['Buy', 2, 5],
        ['milk', 8, 12],
        ['tomorrow', 13, 21],
      ]);
      expect(result.tokens.every((t) => !t.quoted), isTrue);
    });

    test('marks words inside balanced double quotes as quoted and reports the quotes', () {
      final result = tokenize('Review "may 3" report');
      expect([for (final t in result.tokens) [t.text, t.quoted]], [
        ['Review', false],
        ['may', true],
        ['3', true],
        ['report', false],
      ]);
      expect([for (final s in result.quoteSpans) s.start], [7, 13]);
    });

    test('treats an unmatched quote as an ordinary character', () {
      final result = tokenize('5" screen');
      expect([for (final t in result.tokens) t.text], ['5"', 'screen']);
      expect(result.quoteSpans, isEmpty);
    });

    test('normalises case, diacritics, ß and trailing commas', () {
      expect(normalize('Nächsten'), 'nachsten');
      expect(normalize('Straße'), 'strasse');
      expect(normalize('Mañana,'), 'manana');
      expect(normalize('aujourd’hui'), "aujourd'hui");
    });

    test('stripSpans collapses whitespace and deletes quote characters without a gap', () {
      const line = 'Buy  milk tomorrow   p2';
      expect(
        stripSpans(line, [Span(10, 18, 'tomorrow'), Span(21, 23, 'p2')]),
        'Buy milk',
      );
      expect(stripSpans('"Read"!', [], [Span(0, 1, '"'), Span(5, 6, '"')]), 'Read!');
      expect(stripSpans('  a   b  ', []), 'a b');
    });
  });

  group('attribute tokens', () {
    test('matches projects exactly first, then by unique prefix, case-insensitively', () {
      expect(matchProject('#work', projects)?.id, 'p-work');
      expect(matchProject('#WORK', projects)?.id, 'p-work');
      expect(matchProject('#trav', projects)?.id, 'p-travel');
      // "home" is an exact match even though it is also a prefix of "Homework".
      expect(matchProject('#home', projects)?.id, 'p-home');
      expect(matchProject('#homew', projects)?.id, 'p-homework');
    });

    test('does not guess an ambiguous prefix or an unknown name', () {
      expect(matchProject('#hom', projects), isNull);
      expect(matchProject('#ambiguous', projects), isNull);
      expect(matchProject('#', projects), isNull);
      expect(matchProject('work', projects), isNull);
    });

    test('skips archived and deleted projects', () {
      expect(matchProject('#oldies', projects), isNull);
      expect(matchProject('#garden', projects), isNull);
    });

    test('matches nested projects anywhere in the tree', () {
      const tree = [
        ProjectRef(id: 'work', name: 'Work'),
        ProjectRef(id: 'w-docs', name: 'Docs', parentId: 'work'),
        ProjectRef(id: 'w-q4', name: 'Q4 launch', parentId: 'w-docs'),
        ProjectRef(id: 'home', name: 'Home'),
        ProjectRef(id: 'h-docs', name: 'Docs', parentId: 'home'),
        ProjectRef(id: 'h-deep', name: 'Paperwork', parentId: 'h-docs'),
        ProjectRef(id: 'top-paper', name: 'Paperwork'),
      ];
      expect(matchProject('#q4launch', tree)?.id, 'w-q4');
      expect(matchProject('#q4', tree)?.id, 'w-q4');
      // Same exact name at the same depth: smallest id; at different depths: the shallowest.
      expect(matchProject('#docs', tree)?.id, 'h-docs');
      expect(matchProject('#paperwork', tree)?.id, 'top-paper');
      expect(matchProject('#paperwork', tree.reversed.toList())?.id, 'top-paper');
      // An ambiguous prefix is still not guessed.
      expect(matchProject('#doc', tree), isNull);
    });

    test('treats a child of an archived parent as top level and survives parent cycles', () {
      const ps = [
        ProjectRef(id: 'arch', name: 'Old', archived: true),
        ProjectRef(id: 'a', name: 'Notes', parentId: 'arch'),
        ProjectRef(id: 'x', name: 'Loop', parentId: 'y'),
        ProjectRef(id: 'y', name: 'Notes', parentId: 'x'),
      ];
      expect(matchProject('#notes', ps)?.id, 'a');
      expect(matchProject('#loop', ps)?.id, 'x');
    });

    test('matches multi-word project names written without spaces', () {
      const ps = [ProjectRef(id: 'x', name: 'Side Project')];
      expect(matchProject('#sideproject', ps)?.id, 'x');
      expect(matchProject('#side-project', ps)?.id, 'x');
      expect(matchProject('#side', ps)?.id, 'x');
    });

    test('keeps @label names exactly as typed', () {
      expect(matchLabel('@call'), 'call');
      expect(matchLabel('@Waiting-For'), 'Waiting-For');
      expect(matchLabel('@call,'), 'call');
      expect(matchLabel('@'), isNull);
      expect(matchLabel('me@example.com'), isNull);
    });

    test('recognises p1–p4 only', () {
      expect([matchPriority('p1'), matchPriority('P2'), matchPriority('p3'), matchPriority('p4')], [1, 2, 3, 4]);
      expect(matchPriority('p5'), isNull);
      expect(matchPriority('p0'), isNull);
      expect(matchPriority('p12'), isNull);
      expect(matchPriority('pp1'), isNull);
    });

    test('durations become minutes', () {
      const ok = {
        '+30m': 30,
        '+30': 30,
        '+45min': 45,
        '+2h': 120,
        '+1h30': 90,
        '+1h30m': 90,
        '+1.5h': 90,
        '+1,5h': 90,
        '45min': 45,
        '2h': 120,
        '+10080m': 10080,
      };
      for (final e in ok.entries) {
        expect(matchDuration(e.key, bareHourIsTime: false), e.value, reason: e.key);
      }
    });

    test('rejects out-of-range and unitless durations', () {
      for (final token in ['+0', '+0m', '+10081', '30m', '1h30', '+1h75', '+', '+abc', '+-5', 'h']) {
        expect(matchDuration(token, bareHourIsTime: false), isNull, reason: token);
      }
    });

    test('leaves a bare "15h" to the time grammar when a language writes times that way', () {
      expect(matchDuration('2h', bareHourIsTime: true), isNull);
      expect(matchDuration('+2h', bareHourIsTime: true), 120);
    });
  });

  group('vocabularies', () {
    test('bundles en, de, fr, it, es, pt and nl', () {
      expect(vocabularies.keys.toList()..sort(), ['de', 'en', 'es', 'fr', 'it', 'nl', 'pt']);
    });

    test('every vocabulary defines the same keys and table shapes', () {
      for (final code in vocabularies.keys) {
        final v = vocabularies[code]!;
        expect(v.code, code);
        expect(v.weekdays.length, 7, reason: code);
        expect(v.months.length, 12, reason: code);
        expect(v.units.minute.isNotEmpty, isTrue);
        expect(v.units.hour.isNotEmpty, isTrue);
        expect(v.units.day.isNotEmpty, isTrue);
        expect(v.units.week.isNotEmpty, isTrue);
        expect(v.units.month.isNotEmpty, isTrue);
        expect(v.units.year.isNotEmpty, isTrue);
        for (final wd in v.weekdays) {
          expect(wd.isNotEmpty, isTrue, reason: code);
        }
        for (final m in v.months) {
          expect(m.names.isNotEmpty, isTrue, reason: code);
        }
        expect(v.dayWords.values, contains(0), reason: code);
        expect(v.dayWords.values, contains(1), reason: code);
        for (final t in v.timeWords.values) {
          expect(RegExp(r'^\d\d:\d\d$').hasMatch(t), isTrue, reason: '$code $t');
        }
      }
    });

    test('active languages follow the browser list, filtered to bundled ones, with English always on', () {
      expect(activeLanguages(['de-CH', 'fr', 'en-US']), ['de', 'fr', 'en']);
      expect(activeLanguages(['it']), ['it', 'en']);
      expect(activeLanguages(['ja', 'zh-CN']), ['en']);
      expect(activeLanguages([]), ['en']);
      expect(activeLanguages(['pt-BR', 'pt-PT']), ['pt', 'en']);
    });
  });

  group('calendar rules', () {
    test('bare weekday is the next occurrence after today', () {
      expect(nextWeekday(todayIso, 4), '2026-10-16'); // Friday → next Friday
      expect(nextWeekday(todayIso, 5), '2026-10-10'); // Saturday tomorrow
    });

    test('"next <weekday>" skips a day that is still in the current week', () {
      expect(nextNextWeekday(todayIso, 5), '2026-10-17'); // Sat is this week → the following one
      expect(nextNextWeekday(todayIso, 2), '2026-10-14'); // Wed is already next week
      expect(nextNextWeekday('2026-10-05', 2), '2026-10-14'); // from a Monday: Wed of next week
    });
  });

  group('date phrases (English)', () {
    const cases = <String, String>{
      'today': '2026-10-09',
      'tonight': '2026-10-09',
      'tomorrow': '2026-10-10',
      'tmrw': '2026-10-10',
      'day after tomorrow': '2026-10-11',
      'Monday': '2026-10-12',
      'fri': '2026-10-16',
      'on Friday': '2026-10-16',
      'due wed.': '2026-10-14',
      'next Monday': '2026-10-12',
      'next sat': '2026-10-17',
      'this sat': '2026-10-10',
      'in 3 days': '2026-10-12',
      'in 1 day': '2026-10-10',
      'in 2 weeks': '2026-10-23',
      'in a week': '2026-10-16',
      'in a month': '2026-11-09',
      'next week': '2026-10-12',
      'next month': '2026-11-01',
      '3 Feb': '2027-02-03',
      'Feb 3': '2027-02-03',
      '3rd of February': '2027-02-03',
      'December 25th': '2026-12-25',
      'dec 25 2027': '2027-12-25',
      'October 9': '2026-10-09',
      'oct 8': '2027-10-08',
      'may': '2027-05-01',
      'mar 3': '2027-03-03',
      '12/11': '2026-12-11',
      '25/12': '2026-12-25',
      '1/2/2027': '2027-01-02',
      '2026-11-03': '2026-11-03',
    };
    test('date phrases resolve to their day and are removed from the title', () {
      for (final e in cases.entries) {
        final r = dueOf(e.key);
        expect(r.due, Due(e.value), reason: e.key);
        expect(r.title, '', reason: e.key);
      }
    });

    test('month abbreviations need a day number', () {
      expect(dueOf('mar').due, isNull);
      expect(dueOf('jan').due, isNull);
    });

    test('numeric dates follow the day/month order', () {
      expect(dueOf('12/11', dayMonthOrder: DayMonthOrder.dm).due, const Due('2026-11-12'));
      expect(dueOf('12/11', languages: const ['de']).due, const Due('2026-11-12'));
      expect(dueOf('12/11', languages: const ['de'], dayMonthOrder: DayMonthOrder.md).due, const Due('2026-12-11'));
    });

    test('a date in the past rolls forward, Feb 29 to the next leap year', () {
      expect(dueOf('1/10').due, const Due('2027-01-10'));
      expect(dueOf('Feb 29').due, const Due('2028-02-29'));
      expect(dueOf('Feb 30').due, isNull);
    });

    test('in N months clamps to the end of the month', () {
      expect(dueOf('in 1 month', today: '2027-01-31').due, const Due('2027-02-28'));
    });
  });

  group('time phrases', () {
    const cases = <String, String>{
      'at 3pm': '15:00',
      '3pm': '15:00',
      '3 pm': '15:00',
      '3:30pm': '15:30',
      '3:30 p.m.': '15:30',
      '12am': '00:00',
      '12pm': '12:00',
      '11:15 am': '11:15',
      '16:30': '16:30',
      'at 16:30': '16:30',
      'at 9': '09:00',
      'at 9.30': '09:30',
      'noon': '12:00',
      'at midnight': '00:00',
      'in 3 hours': '13:00',
    };
    test('time phrases resolve to today with their clock time', () {
      for (final e in cases.entries) {
        final r = dueOf(e.key);
        expect(r.due, Due(todayIso, e.value), reason: e.key);
        expect(r.title, '', reason: e.key);
      }
    });

    test('a time alone means today, even if already past', () {
      expect(dueOf('at 8am').due, const Due(todayIso, '08:00'));
    });

    test('"in N hours" crosses midnight', () {
      expect(dueOf('in 2 hours', now: '23:30').due, const Due('2026-10-10', '01:30'));
    });

    test('bare numbers are not times', () {
      final r = parse('Buy 3 apples', ctx());
      expect(r.due, isNull);
      expect(r.title, 'Buy 3 apples');
      expect(parse('Read 9.30 notes', ctx()).due, isNull);
      expect(parse('Order 13pm', ctx()).due, isNull);
      expect(parse('Meet 25:00', ctx()).due, isNull);
    });

    test('combines a date and a time anywhere in the line', () {
      expect(dueOf('next Wed at 3pm').due, const Due('2026-10-14', '15:00'));
      final r = parse('tomorrow #work 9am call', ctx());
      expect(r.due, const Due('2026-10-10', '09:00'));
      expect(r.title, 'call');
    });

    test('exposes matchers for direct use', () {
      final d = DateContext(today: todayIso, now: nowHhmm, vocabs: vocabulariesFor(['en']), dayMonthOrder: DayMonthOrder.md);
      final tokens = tokenize('see you next friday at 5pm').tokens;
      final dm = matchDateAt(tokens, 2, d)!;
      expect([dm.date, dm.from, dm.to], ['2026-10-16', 2, 4]);
      final tm = matchTimeAt(tokens, 4, d)!;
      expect([tm.time, tm.from, tm.to], ['17:00', 4, 6]);
      expect(matchDateAt(tokens, 0, d), isNull);
    });
  });

  group('date and time phrases in other languages', () {
    final cases = <({String lang, String phrase, Map<String, String>? due})>[
      // German
      (lang: 'de', phrase: 'heute', due: {'date': '2026-10-09'}),
      (lang: 'de', phrase: 'morgen', due: {'date': '2026-10-10'}),
      (lang: 'de', phrase: 'übermorgen', due: {'date': '2026-10-11'}),
      (lang: 'de', phrase: 'uebermorgen', due: null),
      (lang: 'de', phrase: 'am Freitag', due: {'date': '2026-10-16'}),
      (lang: 'de', phrase: 'Mi.', due: {'date': '2026-10-14'}),
      (lang: 'de', phrase: 'nächsten Mittwoch um 15 Uhr', due: {'date': '2026-10-14', 'time': '15:00'}),
      (lang: 'de', phrase: 'nächsten Samstag', due: {'date': '2026-10-17'}),
      (lang: 'de', phrase: 'in 3 Tagen', due: {'date': '2026-10-12'}),
      (lang: 'de', phrase: 'in einer Woche', due: {'date': '2026-10-16'}),
      (lang: 'de', phrase: 'nächste Woche', due: {'date': '2026-10-12'}),
      (lang: 'de', phrase: 'nächsten Monat', due: {'date': '2026-11-01'}),
      (lang: 'de', phrase: '3. Februar', due: {'date': '2027-02-03'}),
      (lang: 'de', phrase: '12.11.', due: {'date': '2026-11-12'}),
      (lang: 'de', phrase: '24.12.2026', due: {'date': '2026-12-24'}),
      (lang: 'de', phrase: '12.11', due: {'date': '2026-11-12'}),
      (lang: 'de', phrase: '9.30', due: null),
      (lang: 'de', phrase: '14:30 Uhr', due: {'date': todayIso, 'time': '14:30'}),
      (lang: 'de', phrase: 'um 9', due: {'date': todayIso, 'time': '09:00'}),
      (lang: 'de', phrase: 'März 3', due: {'date': '2027-03-03'}),
      // French
      (lang: 'fr', phrase: "aujourd'hui", due: {'date': '2026-10-09'}),
      (lang: 'fr', phrase: 'demain à 15h', due: {'date': '2026-10-10', 'time': '15:00'}),
      (lang: 'fr', phrase: 'après-demain', due: {'date': '2026-10-11'}),
      (lang: 'fr', phrase: 'mardi prochain', due: {'date': '2026-10-13'}),
      (lang: 'fr', phrase: 'samedi prochain', due: {'date': '2026-10-17'}),
      (lang: 'fr', phrase: 'le vendredi', due: {'date': '2026-10-16'}),
      (lang: 'fr', phrase: 'dans 2 semaines', due: {'date': '2026-10-23'}),
      (lang: 'fr', phrase: 'dans 3 jours', due: {'date': '2026-10-12'}),
      (lang: 'fr', phrase: 'la semaine prochaine', due: null),
      (lang: 'fr', phrase: 'semaine prochaine', due: {'date': '2026-10-12'}),
      (lang: 'fr', phrase: '3 février', due: {'date': '2027-02-03'}),
      (lang: 'fr', phrase: '15h30', due: {'date': todayIso, 'time': '15:30'}),
      (lang: 'fr', phrase: 'à 9 heures', due: {'date': todayIso, 'time': '09:00'}),
      (lang: 'fr', phrase: 'midi', due: {'date': todayIso, 'time': '12:00'}),
      // Italian
      (lang: 'it', phrase: 'oggi', due: {'date': '2026-10-09'}),
      (lang: 'it', phrase: 'domani alle 15', due: {'date': '2026-10-10', 'time': '15:00'}),
      (lang: 'it', phrase: 'dopodomani', due: {'date': '2026-10-11'}),
      (lang: 'it', phrase: 'mercoledì', due: {'date': '2026-10-14'}),
      (lang: 'it', phrase: 'lunedì prossimo', due: {'date': '2026-10-12'}),
      (lang: 'it', phrase: 'prossimo sabato', due: {'date': '2026-10-17'}),
      (lang: 'it', phrase: 'tra 3 giorni', due: {'date': '2026-10-12'}),
      (lang: 'it', phrase: 'fra una settimana', due: {'date': '2026-10-16'}),
      (lang: 'it', phrase: 'il 3 febbraio', due: {'date': '2027-02-03'}),
      (lang: 'it', phrase: 'alle 18:45', due: {'date': todayIso, 'time': '18:45'}),
      (lang: 'it', phrase: 'mezzogiorno', due: {'date': todayIso, 'time': '12:00'}),
      // Spanish
      (lang: 'es', phrase: 'hoy', due: {'date': '2026-10-09'}),
      (lang: 'es', phrase: 'mañana a las 15:00', due: {'date': '2026-10-10', 'time': '15:00'}),
      (lang: 'es', phrase: 'pasado mañana', due: {'date': '2026-10-11'}),
      (lang: 'es', phrase: 'el próximo lunes', due: {'date': '2026-10-12'}),
      (lang: 'es', phrase: 'martes que viene', due: {'date': '2026-10-13'}),
      (lang: 'es', phrase: 'en 3 días', due: {'date': '2026-10-12'}),
      (lang: 'es', phrase: 'dentro de 2 semanas', due: {'date': '2026-10-23'}),
      (lang: 'es', phrase: '3 de febrero', due: {'date': '2027-02-03'}),
      (lang: 'es', phrase: 'el 25 de diciembre', due: {'date': '2026-12-25'}),
      (lang: 'es', phrase: 'a las 9', due: {'date': todayIso, 'time': '09:00'}),
      // Portuguese
      (lang: 'pt', phrase: 'hoje', due: {'date': '2026-10-09'}),
      (lang: 'pt', phrase: 'amanhã às 15h', due: {'date': '2026-10-10', 'time': '15:00'}),
      (lang: 'pt', phrase: 'depois de amanhã', due: {'date': '2026-10-11'}),
      (lang: 'pt', phrase: 'sexta-feira', due: {'date': '2026-10-16'}),
      (lang: 'pt', phrase: 'próxima segunda', due: {'date': '2026-10-12'}),
      (lang: 'pt', phrase: 'sábado que vem', due: {'date': '2026-10-17'}),
      (lang: 'pt', phrase: 'daqui a 3 dias', due: {'date': '2026-10-12'}),
      (lang: 'pt', phrase: 'em 2 semanas', due: {'date': '2026-10-23'}),
      (lang: 'pt', phrase: '3 de fevereiro', due: {'date': '2027-02-03'}),
      (lang: 'pt', phrase: 'às 9', due: {'date': todayIso, 'time': '09:00'}),
    ];
    test('every language resolves its own phrases', () {
      for (final c in cases) {
        final r = dueOf(c.phrase, languages: [c.lang]);
        if (c.due == null) {
          // Not (fully) a phrase: some text must remain in the title.
          expect(r.title, isNotEmpty, reason: '${c.lang} ${c.phrase}');
        } else {
          expect(r.due, Due(c.due!['date']!, c.due!['time']), reason: '${c.lang} ${c.phrase}');
          expect(r.title, '', reason: '${c.lang} ${c.phrase}');
        }
      }
    });

    test('all active languages match at once, English always included', () {
      expect(parse('Pay rent tomorrow', ctx(languages: const ['it'])).due, const Due('2026-10-10'));
      expect(parse('Pagare affitto domani', ctx(languages: const ['it'])).due, const Due('2026-10-10'));
      // German vocabulary is off unless German is active.
      expect(parse('Zahnarzt morgen', ctx(languages: const ['en'])).due, isNull);
    });

    test('longest match decides collisions ("mar" = Tuesday in Spanish, March next to a day)', () {
      expect(parse('Pagar mar', ctx(languages: const ['es'])).due, const Due('2026-10-13'));
      expect(parse('Pay mar 3', ctx(languages: const ['es'])).due, const Due('2027-03-03'));
    });

    test('a bare "15h" is a duration in English and a time in French', () {
      expect(parse('Workshop 2h', ctx(languages: const ['en'])).estimateMinutes, 120);
      final fr = parse('Atelier 15h', ctx(languages: const ['fr']));
      expect(fr.estimateMinutes, isNull);
      expect(fr.due, const Due(todayIso, '15:00'));
    });
  });

  group('parse: spec scenarios', () {
    test('full line', () {
      final r = parse('Meeting with Sarah #work @call p1 +30m', ctx());
      expectMatch(r, {
        'title': 'Meeting with Sarah',
        'projectId': 'p-work',
        'labels': ['call'],
        'priority': 1,
        'estimateMinutes': 30,
        'due': null,
      });
      expect([for (final c in r.chips) c.kind], ['project', 'label', 'priority', 'estimate']);
    });

    test('full line with a date and time', () {
      final r = parse('Meeting with Sarah next Wed at 3pm #work @call p1 +30m', ctx());
      expectMatch(r, {
        'title': 'Meeting with Sarah',
        'due': {'date': '2026-10-14', 'time': '15:00'},
        'projectId': 'p-work',
        'labels': ['call'],
        'priority': 1,
        'estimateMinutes': 30,
      });
      expect([for (final c in r.chips) c.kind], ['due', 'project', 'label', 'priority', 'estimate']);
      expect(chipJson(r.chips[0])['spans'], [
        {'start': 19, 'end': 27, 'text': 'next Wed'},
        {'start': 28, 'end': 34, 'text': 'at 3pm'},
      ]);
    });

    test('unknown project token stays literal', () {
      final r = parse('Read #ambiguous', ctx());
      expect(r.title, 'Read #ambiguous');
      expect(r.projectId, isNull);
      expect(r.chips, isEmpty);
    });

    test('ambiguous prefix is not guessed', () {
      final r = parse('Fix sink #hom', ctx());
      expect(r.title, 'Fix sink #hom');
      expect(r.projectId, isNull);
      expect(r.chips.any((c) => c.kind == 'project'), isFalse);
    });

    test('next weekday with time', () {
      expectMatch(parse('Dentist next Wed at 3pm', ctx()), {
        'title': 'Dentist',
        'due': {'date': '2026-10-14', 'time': '15:00'},
      });
    });

    test('time only', () {
      expectMatch(parse('Call back 16:30', ctx()), {
        'title': 'Call back',
        'due': {'date': todayIso, 'time': '16:30'},
      });
    });

    test('date in the past rolls forward', () {
      expectMatch(parse('Renew passport 3 Feb', ctx()), {
        'title': 'Renew passport',
        'due': {'date': '2027-02-03'},
      });
    });

    test('German phrase', () {
      expectMatch(parse('Zahnarzt nächsten Mittwoch um 15 Uhr', ctx(languages: const ['de'])), {
        'title': 'Zahnarzt',
        'due': {'date': '2026-10-14', 'time': '15:00'},
      });
    });

    test('unsupported language falls back to English and attribute tokens still work', () {
      final r = parse('Pay rent tomorrow p2 #work', ctx(languages: const ['ja-JP']));
      expectMatch(r, {
        'title': 'Pay rent',
        'due': {'date': '2026-10-10'},
        'priority': 2,
        'projectId': 'p-work',
      });
    });

    test('chips appear as tokens are typed and disappear when text changes', () {
      final r = parse('Buy milk tomorrow p2', ctx());
      expect(r.title, 'Buy milk');
      expect([
        for (final c in r.chips) [c.kind, chipValueJson(c.value)],
      ], [
        ['due', {'date': '2026-10-10'}],
        ['priority', 2],
      ]);
      final after = parse('Buy milk tomorrow ', ctx());
      expect([for (final c in after.chips) c.kind], ['due']);
      expect(after.priority, isNull);
    });

    test('explicit tokens are reported so they can override view defaults', () {
      expectMatch(parse('Plan trip next Monday #travel', ctx()), {
        'title': 'Plan trip',
        'due': {'date': '2026-10-12'},
        'projectId': 'p-travel',
      });
    });
  });

  group('parse: escaping and dismissal', () {
    test('quoted text is never parsed and the quotes are removed', () {
      final r = parse('Review "may" report', ctx());
      expect(r.title, 'Review may report');
      expect(r.due, isNull);
      expect(r.chips, isEmpty);
      final p1 = parse('Ship "p1 #work" docs', ctx());
      expectMatch(p1, {'title': 'Ship p1 #work docs', 'priority': null, 'projectId': null});
      expectMatch(parse('Watch "Next Friday" tomorrow', ctx()), {
        'title': 'Watch Next Friday',
        'due': {'date': '2026-10-10'},
      });
    });

    test('a dismissed span is kept literally', () {
      const line = 'Review may report';
      final first = parse(line, ctx());
      expect(first.due, const Due('2027-05-01'));
      expect(first.title, 'Review report');
      final r = parse(line, ctx(dismissed: first.chips[0].spans));
      expect(r.title, 'Review may report');
      expect(r.due, isNull);
      expect(r.chips, isEmpty);
    });

    test('a dismissal survives further typing and lapses when its text changes', () {
      const line = 'Review may report';
      final dismissed = parse(line, ctx()).chips[0].spans;
      final longer = '$line with Ana';
      final kept = rebaseDismissed(line, longer, dismissed);
      expect(parse(longer, ctx(dismissed: kept)).due, isNull);
      // Editing the dismissed word itself drops the dismissal.
      expect(parse('Review May 3 report', ctx(dismissed: dismissed)).due, const Due('2027-05-03'));
    });

    test('a dismissal ignores spans whose text no longer matches', () {
      final r = parse('tomorrow call', ctx(dismissed: [const Span(0, 3, 'may')]));
      expect(r.due, const Due('2026-10-10'));
    });

    test('dismissing one chip keeps the others', () {
      const line = 'Plan p1 trip #travel';
      final p = parse(line, ctx()).chips.firstWhere((c) => c.kind == 'priority');
      final r = parse(line, ctx(dismissed: p.spans));
      expectMatch(r, {'title': 'Plan p1 trip', 'priority': null, 'projectId': 'p-travel'});
    });
  });

  group('parse: day parts (day-parts D5)', () {
    test('a part after a date is a dismissable chip; dismissing it keeps the word', () {
      const line = 'Stretch tomorrow morning';
      final r = parse(line, ctx(dayParts: true));
      final chip = r.chips.firstWhere((c) => c.kind == 'daypart');
      expect(chip.value, 'morning');
      expectMatch(r, {'title': 'Stretch', 'dayPart': 'morning'});
      expectMatch(parse(line, ctx(dayParts: true, dismissed: chip.spans)), {
        'title': 'Stretch morning',
        'dayPart': null,
      });
    });

    test('quoted words stay in the title', () {
      expectMatch(parse('"Stretch this morning"', ctx(dayParts: true)), {'dayPart': null, 'due': null});
    });
  });

  group('parse: energy (task-energy D4)', () {
    test('a token is a chip; dismissing it keeps the text', () {
      const line = 'Draft the plan ~deep';
      final r = parse(line, ctx(energy: true));
      final chip = r.chips.firstWhere((c) => c.kind == 'energy');
      expect(chip.value, 'deep');
      expectMatch(r, {'title': 'Draft the plan', 'energy': 'deep'});
      expectMatch(parse(line, ctx(energy: true, dismissed: chip.spans)), {
        'title': 'Draft the plan ~deep',
        'energy': null,
      });
    });

    test('the last token wins and every token leaves the title', () {
      final r = parse('Plan ~l the week ~DEEP', ctx(energy: true));
      expectMatch(r, {'title': 'Plan the week', 'energy': 'deep'});
      expect(r.chips.where((c) => c.kind == 'energy').length, 1);
    });

    test('is not read while the switch is off, and ~ followed by anything else stays', () {
      expectMatch(parse('Call ~low', ctx()), {'title': 'Call ~low', 'energy': null, 'chips': []});
      expectMatch(parse('Dinner for ~6 people ~x', ctx(energy: true)), {
        'title': 'Dinner for ~6 people ~x',
        'energy': null,
      });
    });
  });

  group('parse: precedence and passthrough', () {
    test('no match passes the line through, whitespace collapsed', () {
      final r = parse('  Buy   oat milk  ', ctx());
      expect(shape(r), {
        'title': 'Buy oat milk',
        'due': null,
        'deadline': null,
        'start': null,
        'sector': null,
        'evening': false,
        'dayPart': null,
        'projectId': null,
        'labels': <String>[],
        'priority': null,
        'energy': null,
        'estimateMinutes': null,
        'spentMinutes': null,
        'recurrence': null,
        'reminders': <Object?>[],
        'chips': <Object?>[],
        'unmatched': <Object?>[],
      });
    });

    test('first match of each attribute wins; later ones stay in the title', () {
      expectMatch(parse('Call p1 p2', ctx()), {'title': 'Call p2', 'priority': 1});
      expectMatch(parse('Send tomorrow friday', ctx()), {'title': 'Send friday', 'due': {'date': '2026-10-10'}});
      expectMatch(parse('Gym #work #home', ctx()), {'title': 'Gym #home', 'projectId': 'p-work'});
      expectMatch(parse('Read +30m +1h', ctx()), {'title': 'Read +1h', 'estimateMinutes': 30});
    });

    test('keeps every @label, as typed, in order', () {
      expectMatch(parse('Ask @Call @waiting-for Bob', ctx()), {
        'title': 'Ask Bob',
        'labels': ['Call', 'waiting-for'],
      });
    });

    test('does not treat email addresses or words containing tokens as attributes', () {
      expectMatch(parse('Mail bob@example.com about p1x', ctx()), {
        'title': 'Mail bob@example.com about p1x',
        'labels': <String>[],
        'priority': null,
      });
    });

    test('swallows a leading preposition only together with a date', () {
      expect(parse('Pay bill by Friday', ctx()).title, 'Pay bill');
      expect(parse('Stand by me', ctx()).title, 'Stand by me');
    });
  });

  group('parse: determinism', () {
    test('same input twice yields deep-equal output', () {
      const line = 'Meeting with Sarah next Wed at 3pm #work @call p1 +30m';
      expect(shape(parse(line, ctx())), shape(parse(line, ctx())));
    });

    test('a shuffled project list yields the same result', () {
      const line = 'Plan trip next Monday #trav @x p3 +1h30';
      final base = shape(parse(line, ctx()));
      for (final order in [
        [5, 4, 3, 2, 1, 0],
        [2, 0, 5, 1, 4, 3],
        [3, 1, 0, 2, 5, 4],
      ]) {
        expect(shape(parse(line, ctx(projects: [for (final k in order) projects[k]]))), base);
      }
      // Two projects with the same name resolve to the same one regardless of order.
      const dupes = [ProjectRef(id: 'b', name: 'Work'), ProjectRef(id: 'a', name: 'work')];
      expect(parse('x #work', ctx(projects: dupes)).projectId, 'a');
      expect(parse('x #work', ctx(projects: dupes.reversed.toList())).projectId, 'a');
    });

    test('the language order changes nothing for unambiguous phrases', () {
      const line = 'Zahnarzt morgen um 9 Uhr';
      expect(shape(parse(line, ctx(languages: const ['de', 'fr']))), shape(parse(line, ctx(languages: const ['fr', 'de']))));
    });
  });

  group('rebaseDismissed', () {
    const d = [Span(7, 10, 'may')];

    test('keeps spans before an edit at the end', () {
      expect(rebaseDismissed('Review may', 'Review may report', d), d);
    });

    test('shifts spans after an edit before them', () {
      expect(rebaseDismissed('Review may', 'Please Review may', d), [const Span(14, 17, 'may')]);
    });

    test('drops spans the edit touches', () {
      expect(rebaseDismissed('Review may', 'Review mayo', d), isEmpty);
      expect(rebaseDismissed('Review may', 'Review ma', d), isEmpty);
    });

    test('handles deletions before a span', () {
      expect(rebaseDismissed('Do Review may', 'Review may', [const Span(10, 13, 'may')]), d);
    });
  });

  group('deadline phrases (OpenSpec deadlines 7.1)', () {
    // Wednesday 2026-10-14 in these scenarios.
    ParseResult at(String line, {List<String> languages = const ['en'], List<Span> dismissed = const []}) =>
        parse(line, ctx(today: '2026-10-14', languages: languages, dismissed: dismissed));

    test('deadline only', () {
      final r = at('Send report deadline friday');
      expectMatch(r, {'title': 'Send report', 'due': null, 'deadline': '2026-10-16'});
      expect([for (final c in r.chips) c.kind], ['deadline']);
    });

    test('plan and deadline', () {
      final r = at('Send report tomorrow deadline friday');
      expectMatch(r, {'title': 'Send report', 'due': {'date': '2026-10-15'}, 'deadline': '2026-10-16'});
    });

    test('German phrase', () {
      expectMatch(at('Bericht Frist 3. November', languages: const ['de']), {
        'title': 'Bericht',
        'deadline': '2026-11-03',
      });
    });

    test('other languages, accents optional', () {
      expect(at('Rapport échéance vendredi', languages: const ['fr']).deadline, '2026-10-16');
      expect(at('Rapport echeance vendredi', languages: const ['fr']).deadline, '2026-10-16');
      expectMatch(at('Informe fecha límite viernes', languages: const ['es']), {
        'title': 'Informe',
        'deadline': '2026-10-16',
      });
      expect(at('Relazione scadenza venerdì', languages: const ['it']).deadline, '2026-10-16');
      expect(at('Relatório prazo sexta', languages: const ['pt']).deadline, '2026-10-16');
    });

    test('without a date after it, the word stays in the title', () {
      expectMatch(at('Review deadline policy tomorrow'), {
        'title': 'Review deadline policy',
        'due': {'date': '2026-10-15'},
        'deadline': null,
      });
    });

    test('a time after the deadline stays in the title', () {
      expectMatch(at('Call deadline friday 15:00'), {
        'title': 'Call 15:00',
        'deadline': '2026-10-16',
        'due': null,
      });
    });

    test('only the first deadline phrase counts', () {
      final r = at('Plan deadline friday deadline monday');
      expect(r.deadline, '2026-10-16');
      expect(r.title, contains('deadline'));
    });

    test('a dismissed deadline chip keeps the words as text', () {
      final first = at('Send report deadline friday');
      final dismissed = first.chips.firstWhere((c) => c.kind == 'deadline').spans;
      expectMatch(at('Send report deadline friday', dismissed: dismissed), {
        'title': 'Send report deadline friday',
        'deadline': null,
        'due': null,
      });
    });

    test('on and due keep setting the due date', () {
      expectMatch(at('Pay rent on friday'), {'title': 'Pay rent', 'due': {'date': '2026-10-16'}, 'deadline': null});
      expectMatch(at('Pay rent due friday'), {'due': {'date': '2026-10-16'}, 'deadline': null});
    });

    test('by sets the deadline, with a deadline chip (quick-add-by-deadline)', () {
      final r = at('Pay rent by friday');
      expectMatch(r, {'title': 'Pay rent', 'due': null, 'deadline': '2026-10-16'});
      expect([for (final c in r.chips) c.kind], ['deadline']);
      expect(r.chips[0].spans[0].text, 'by friday');
    });

    test('by with a time sets the due date and time', () {
      expectMatch(at('Call back by 5pm'), {
        'title': 'Call back',
        'due': {'date': '2026-10-14', 'time': '17:00'},
        'deadline': null,
      });
      expectMatch(at('Pay rent by friday 5pm'), {
        'title': 'Pay rent',
        'due': {'date': '2026-10-16', 'time': '17:00'},
        'deadline': null,
      });
    });

    test('a dismissed by phrase stays in the title', () {
      const dismissed = [Span(9, 18, 'by friday')];
      expectMatch(at('Pay rent by friday', dismissed: dismissed), {
        'title': 'Pay rent by friday',
        'deadline': null,
      });
    });
  });

  group('someday and evening phrases (OpenSpec someday-and-evening 5.1)', () {
    ParseResult at(String line, {List<String> languages = const ['en'], List<Span> dismissed = const []}) =>
        parse(line, ctx(today: '2026-10-14', languages: languages, dismissed: dismissed));

    test('park from quick add', () {
      final r = at('Learn to sail someday @hobby');
      expectMatch(r, {'title': 'Learn to sail', 'start': 'someday', 'due': null, 'labels': ['hobby']});
      expect(r.chips.map((c) => c.kind), contains('someday'));
    });

    test('someday with a date stays literal', () {
      expectMatch(at('Plan someday trip friday'), {
        'title': 'Plan someday trip',
        'start': null,
        'due': {'date': '2026-10-16'},
      });
    });

    test('tonight with a time', () {
      final r = at('Call Ana tonight at 8pm');
      expectMatch(r, {'title': 'Call Ana', 'due': {'date': '2026-10-14', 'time': '20:00'}, 'evening': true});
      expect(r.chips.map((c) => c.kind), containsAll(['due', 'evening']));
    });

    test('tonight alone still resolves to today, and this evening works too', () {
      expectMatch(at('Cook tonight'), {'title': 'Cook', 'due': {'date': '2026-10-14'}, 'evening': true});
      expectMatch(at('Cook this evening'), {'title': 'Cook', 'due': {'date': '2026-10-14'}, 'evening': true});
    });

    test('Italian evening and the other languages', () {
      expectMatch(at('Chiama Ana stasera', languages: const ['it']), {
        'title': 'Chiama Ana',
        'due': {'date': '2026-10-14'},
        'evening': true,
      });
      expectMatch(at('Segeln lernen irgendwann', languages: const ['de']), {
        'title': 'Segeln lernen',
        'start': 'someday',
      });
      expectMatch(at('Aprender a navegar algun dia', languages: const ['es']), {
        'title': 'Aprender a navegar',
        'start': 'someday',
      });
    });

    test('a dismissed someday chip keeps the word', () {
      final first = at('Learn to sail someday');
      final dismissed = first.chips.firstWhere((c) => c.kind == 'someday').spans;
      expectMatch(at('Learn to sail someday', dismissed: dismissed), {
        'title': 'Learn to sail someday',
        'start': null,
      });
    });
  });

  group('ordinal weekdays (OpenSpec quick-add-nth-weekday 2.4)', () {
    test('a dismissed ordinal weekday keeps its text in the title and does not come back', () {
      const line = 'Review notes from last Friday';
      final first = parse(line, ctx());
      expectMatch(first, {'title': 'Review notes from', 'due': {'date': '2026-10-30'}});
      final due = first.chips.firstWhere((c) => c.kind == 'due');
      expect([for (final s in due.spans) s.text], ['last Friday']);
      final r = parse(line, ctx(dismissed: due.spans));
      expect(r.title, line);
      expect(r.due, isNull);
      expect(r.chips, isEmpty);
      // Further typing keeps the dismissal while that text is unchanged.
      final longer = '$line with Ana';
      expect(parse(longer, ctx(dismissed: rebaseDismissed(line, longer, due.spans))).due, isNull);
    });

    test('a count before a weekday is a literal match: no chip, the line as typed', () {
      final r = parse('Board every 2 Mondays', ctx());
      expect(r.chips, isEmpty);
      expectMatch(r, {'title': 'Board every 2 Mondays', 'due': null, 'recurrence': null});
      expect(parse('Reunión cada 2 lunes', ctx(languages: const ['es'])).chips, isEmpty);
      expect(parse('Treffen alle 2 Montage', ctx(languages: const ['de', 'it'])).chips, isEmpty);
    });

    test('resolves against the reference date it is given', () {
      expect(parse('Dentist second Monday', ctx(today: '2026-10-12')).due, const Due('2026-10-12'));
      expect(parse('Dentist second Monday', ctx(today: '2026-10-13')).due, const Due('2026-11-09'));
      // (The web test also builds this date with logicalToday(); the logical day is the
      // caller's input here, so only the parse above is kept.)
    });

    test('Portuguese weekday ordinals are listed only where they are weekday names', () {
      for (final v in vocabularies.values) {
        for (final word in v.ordinalsBeforeWeekday.keys) {
          expect(v.weekdays.expand((x) => x).map(normalize), contains(normalize(word)), reason: v.code);
        }
        for (final p in [...v.ordinalArticles, ...v.ordinalOf, ...v.ofMonthWords]) {
          expect(p.trim(), isNotEmpty, reason: v.code);
        }
      }
    });
  });

  // Smart title tokens (OpenSpec change smart-title-tokens, design D2 and D4).
  group('project paths and unmatched tokens', () {
    const ps = [
      ProjectRef(id: 'p-work', name: 'Work'),
      ProjectRef(id: 'p-home', name: 'Home'),
      ProjectRef(id: 'p-homework', name: 'Homework'),
      ProjectRef(id: 'p-work-docs', name: 'Docs', parentId: 'p-work'),
      ProjectRef(id: 'p-home-docs', name: 'Docs', parentId: 'p-home'),
      ProjectRef(id: 'p-reno', name: 'Home renovation'),
    ];
    ParseResult at(String line) => parse(line, ParseContext(today: '2026-10-09', languages: const ['en'], projects: ps));

    test('#Parent/Child picks the child under that parent; a wrong parent matches nothing', () {
      expect(at('Write #Home/Docs').projectId, 'p-home-docs');
      expect(at('Write #work/docs').projectId, 'p-work-docs');
      expectMatch(at('Write #Garden/Docs'), {'projectId': null, 'title': 'Write #Garden/Docs'});
    });

    test('a name with spaces is matched by the token a suggestion inserts', () {
      expect(at('Paint #HomeRenovation').projectId, 'p-reno');
    });

    test('explains a #token that names no project, or several', () {
      expect([for (final m in at('Rake leaves #gardn').unmatched) unmatchedJson(m)], [
        {
          'span': {'start': 12, 'end': 18, 'text': '#gardn'},
          'reason': 'none',
        },
      ]);
      final ambiguous = at('Fix sink #hom').unmatched.single;
      expect(ambiguous.reason, 'ambiguous');
      expect(ambiguous.count, 3);
      expect(at('Fix sink #home').unmatched, isEmpty);
    });
  });

  // Dart specifics the TS source does not exercise: its offsets are UTF-16 code
  // units too, and its normalize() strips combining marks after NFD.
  group('Dart port details', () {
    test('spans are UTF-16 offsets and astral characters survive the title', () {
      final r = parse('Buy 🎉 milk tomorrow', ctx());
      expect(r.title, 'Buy 🎉 milk');
      final span = r.chips.single.spans.single;
      expect([span.start, span.end], [12, 20]);
    });

    test('input with decomposed diacritics folds like the composed form', () {
      expect(normalize('man\u0303ana'), 'manana');
      final r = parse('Pagar man\u0303ana', ctx(languages: const ['es']));
      expect(r.due, const Due('2026-10-10'));
      expect(r.title, 'Pagar');
    });
  });
}
