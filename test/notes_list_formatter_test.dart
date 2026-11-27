import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/ui/notes_field.dart';

void main() {
  const formatter = MarkdownListFormatter();

  TextEditingValue value(String text, [int? offset]) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: offset ?? text.length),
      );

  TextEditingValue enter(TextEditingValue old) => value(
        '${old.text}\n',
        old.selection.baseOffset + 1,
      );

  test('Enter continues a bullet list', () {
    final old = value('- one');
    final result = formatter.formatEditUpdate(old, enter(old));
    expect(result.text, '- one\n- ');
    expect(result.selection.baseOffset, 8);
  });

  test('Enter continues a numbered list with the next number', () {
    final old = value('9. nine');
    final result = formatter.formatEditUpdate(old, enter(old));
    expect(result.text, '9. nine\n10. ');
  });

  test('Enter continues a checklist unchecked', () {
    final old = value('- [x] done');
    final result = formatter.formatEditUpdate(old, enter(old));
    expect(result.text, '- [x] done\n- [ ] ');
  });

  test('Enter on an empty item finishes the list', () {
    final old = value('- one\n- ');
    final result = formatter.formatEditUpdate(old, enter(old));
    expect(result.text, '- one\n');
    expect(result.selection.baseOffset, 6);
  });

  test('a numbered empty item also finishes the list', () {
    final old = value('1. one\n2. ');
    final result = formatter.formatEditUpdate(old, enter(old));
    expect(result.text, '1. one\n');
  });

  test('plain text and multi-character input are untouched', () {
    final old = value('plain');
    final inserted = value('plain\n');
    expect(formatter.formatEditUpdate(old, inserted).text, 'plain\n');
    final pasted = value('a\nb');
    expect(formatter.formatEditUpdate(old, pasted).text, 'a\nb');
  });
}
