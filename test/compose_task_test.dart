// What the composer writes: the merge of the controls and the parsed line.
//
// The composer's save path is a pure function, so it is tested here without the
// widget harness (real SQLite inside `testWidgets`' fake-async zone is a fight
// not worth having). The widget itself is smoke-tested for its preview line.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd_bridge.dart';
import 'package:otda/src/ui/new_task_sheet.dart';

void main() {
  final parsed = ParsedLine(
    title: 'Buy milk',
    fields: {
      'due': {'date': '2026-11-19', 'time': '15:00'},
      'priority': 1,
      'estimate_minutes': 30,
      'recurrence': 'every week',
      'labels': ['l1'],
    },
    chips: ['2026-11-19 15:00', 'p1'],
  );

  test('the parsed line is used when no control was touched', () {
    final fields = composeTaskFields(parsed: parsed, priority: 4);
    expect(fields['priority'], 1);
    expect(fields['due'], {'date': '2026-11-19', 'time': '15:00'});
    expect(fields['estimate_minutes'], 30);
    expect(fields['recurrence'], 'every week');
    // Labels are names on the way out of the parser; the save path resolves them
    // to ids, so they are not part of the create body this returns.
    expect(fields.containsKey('labels'), isFalse);
  });

  test('a control value wins over the parsed one', () {
    final fields = composeTaskFields(
      parsed: parsed,
      priority: 2,
      dueDate: '2026-12-24',
      estimate: 90,
      recurrence: 'every month',
    );
    expect(fields['priority'], 2);
    expect(fields['due'], {'date': '2026-12-24'});
    expect(fields['estimate_minutes'], 90);
    expect(fields['recurrence'], 'every month');
  });

  test('a control date keeps the parsed time when no time was set', () {
    final fields = composeTaskFields(parsed: parsed, priority: 4, dueDate: '2026-12-24', dueTime: null);
    expect(fields['due'], {'date': '2026-12-24'});
  });

  test('an empty line sets only the default priority', () {
    final fields = composeTaskFields(parsed: const ParsedLine(title: ''), priority: 4);
    expect(fields['priority'], 4);
    expect(fields.containsKey('due'), isFalse);
    expect(fields.containsKey('estimate_minutes'), isFalse);
  });
}
