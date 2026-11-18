// The composer's value rules, which are where its bugs live:
//  * clearing the line clears what the line contributed (a picked date stays);
//  * a value set by a control is never overwritten or cleared by the parser.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/quickadd_bridge.dart';
import 'package:otda/src/ui/composer_state.dart';
import 'package:otda/src/ui/new_task_sheet.dart';

ParsedLine parsedWith(Map<String, Object?> fields) => ParsedLine(title: 'Buy milk', fields: fields);

void main() {
  test('clearing the input clears the date it had parsed', () {
    final state = ComposerState();
    state.applyParsed(parsedWith({
      'due': {'date': '2026-11-19'},
      'priority': 1,
      'estimate_minutes': 30,
    }));
    expect(state.dueDate, '2026-11-19');
    expect(state.priority, 1);
    expect(state.estimate, 30);

    state.applyParsed(const ParsedLine(title: ''));

    expect(state.dueDate, isNull, reason: 'the word that set the date is gone');
    expect(state.dueTime, isNull);
    expect(state.priority, 4, reason: 'the default comes back');
    expect(state.estimate, isNull);
  });

  test('a date picked by hand survives clearing the line', () {
    final state = ComposerState();
    state
      ..dueDate = '2026-12-24'
      ..claim('due');
    state.applyParsed(parsedWith({'due': {'date': '2026-11-19'}}));
    expect(state.dueDate, '2026-12-24');

    state.applyParsed(const ParsedLine(title: ''));
    expect(state.dueDate, '2026-12-24', reason: 'nobody typed over it');
  });

  test('a hand-set date is released when the control is cleared', () {
    final state = ComposerState();
    state
      ..dueDate = '2026-12-24'
      ..claim('due')
      ..dueDate = null
      ..release('due');
    state.applyParsed(parsedWith({'due': {'date': '2026-11-19'}}));
    expect(state.dueDate, '2026-11-19', reason: 'the line may fill it again');
  });

  test('parsed recurrence is cleared when the words are deleted', () {
    final state = ComposerState();
    state.applyParsed(parsedWith({'recurrence': 'every week'}));
    expect(state.recurrence, 'every week');
    state.applyParsed(const ParsedLine(title: ''));
    expect(state.recurrence, isNull);
  });

  test('a project chosen by hand is not replaced by a parsed one', () {
    final state = ComposerState(projectId: 'p1');
    state.applyParsed(parsedWith({'project_id': 'p2'}));
    expect(state.projectId, 'p1');
  });

  test('the composer drops fields a task cannot carry', () {
    final fields = composeTaskFields(
      parsed: parsedWith({
        'estimate_minutes': 120,
        'spent_minutes': 30,
        'reminders': [{'offset_minutes': -10}],
        'title': 'ignored',
      }),
      priority: 4,
    );
    expect(fields['estimate_minutes'], 120);
    expect(fields.containsKey('spent_minutes'), isFalse, reason: 'a task field list has no spent time');
    expect(fields.containsKey('reminders'), isFalse, reason: 'a reminder is its own call');
    expect(fields.containsKey('title'), isFalse, reason: 'the title is passed separately');
  });
}
