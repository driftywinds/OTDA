// "in 4m", "in 2h", "in 3d", "in 2w", "in 3mt", "in 1y": the compact relative forms,
// next to the spoken ones, and the highlights the parser hands to the composer.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd/parse.dart';
import 'package:otda/src/quickadd_bridge.dart';
import 'package:otda/src/ui/highlight_controller.dart';

ParseResult at(String line, {String now = '10:00'}) =>
    parse(line, ParseContext(today: '2026-10-09', now: now, languages: const ['en']));

void main() {
  group('in <n><unit>', () {
    test('minutes set a time today', () {
      final r = at('call Sam in 4m');
      expect(r.title, 'call Sam');
      expect(r.due?.toJson(), {'date': '2026-10-09', 'time': '10:04'});
      expect(r.estimateMinutes, isNull);
    });

    test('spoken minutes and long suffixes read the same', () {
      for (final line in ['call in 4 minutes', 'call in 4 min', 'call in 4mins', 'call in 4min']) {
        expect(at(line).due?.toJson(), {'date': '2026-10-09', 'time': '10:04'}, reason: line);
        expect(at(line).title, 'call', reason: line);
      }
    });

    test('hours and large minute counts roll over', () {
      expect(at('x in 2h').due?.toJson(), {'date': '2026-10-09', 'time': '12:00'});
      expect(at('x in 90m').due?.toJson(), {'date': '2026-10-09', 'time': '11:30'});
      expect(at('x in 4m', now: '23:58').due?.toJson(), {'date': '2026-10-10', 'time': '00:02'});
    });

    test('days, weeks, months and years set a date', () {
      expect(at('x in 3d').due?.toJson(), {'date': '2026-10-12'});
      expect(at('x in 2w').due?.toJson(), {'date': '2026-10-23'});
      expect(at('x in 3mt').due?.toJson(), {'date': '2027-01-09'});
      expect(at('x in 3mo').due?.toJson(), {'date': '2027-01-09'});
      expect(at('x in 1y').due?.toJson(), {'date': '2027-10-09'});
      expect(at('x in 2 years').due?.toJson(), {'date': '2028-10-09'});
      expect(at('x in 3d').title, 'x');
    });

    test('a plus still means a duration, not a due time', () {
      final r = at('write +4m');
      expect(r.estimateMinutes, 4);
      expect(r.due, isNull);
    });

    test('a bare compact token without "in" stays text', () {
      final r = at('run 4m');
      expect(r.due, isNull);
      expect(r.title, 'run 4m');
    });
  });

  group('highlights', () {
    test('date and time are told apart, offsets follow the line as typed', () {
      const line = '  call tomorrow 3pm p1';
      final parsed = parseLine(line, today: '2026-10-09', now: '10:00');
      final byKind = {for (final h in parsed.highlights) h.kind: h};
      expect(byKind.keys, containsAll(['date', 'time', 'priority']));
      for (final h in parsed.highlights) {
        expect(line.substring(h.start, h.end), h.text);
      }
      expect(byKind['date']!.text, 'tomorrow');
      expect(byKind['time']!.text, '3pm');
    });

    test('the controller colours only what still matches the text', () {
      final c = HighlightingController(text: 'call in 3d');
      c.highlights = parseLine(c.text, today: '2026-10-09', now: '10:00').highlights;
      expect(c.liveHighlights.map((h) => h.kind), ['date']);
      c.text = 'call in 3d please';
      expect(c.liveHighlights.length, 1);
      c.text = 'call in 4d please';
      expect(c.liveHighlights, isEmpty);
      c.dispose();
    });
  });

  group('highlighting controller', () {
    testWidgets('segments rebuild the whole line', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        }),
      ));
      final c = HighlightingController(text: 'call in 3d now');
      c.highlights = parseLine(c.text, today: '2026-10-09', now: '10:00').highlights;
      final span = c.buildTextSpan(context: context, style: const TextStyle(), withComposing: false);
      final joined = span.children!.map((s) => (s as TextSpan).text).join();
      expect(joined, 'call in 3d now');
      c.dispose();
    });
  });
}
