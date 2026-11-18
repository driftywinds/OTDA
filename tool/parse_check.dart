// Prints what the quick-add parser makes of a line. Pure Dart, so it can be
// run from a terminal: dart run tool/parse_check.dart "call Sam tomorrow 3pm p1 30m"
import 'dart:io';

import 'package:otda/src/quickadd/attributes.dart';
import 'package:otda/src/quickadd/quickadd.dart';

void main(List<String> args) {
  final line = args.isEmpty ? 'call Sam tomorrow 3pm p1 30m' : args.join(' ');
  final now = DateTime.now();
  final today = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  final result = parseQuickAdd(line, today: today, now: clock, projects: const <ProjectRef>[]);
  stdout.writeln('line:    $line');
  stdout.writeln('today:   $today $clock');
  stdout.writeln('title:   "${result.title}"');
  stdout.writeln('fields:  ${result.fields}');
  stdout.writeln('chips:   ${result.chips.length}');
  for (final chip in result.chips) {
    stdout.writeln('  - ${chip.kind} "${chipLabel(chip)}" value=${chip.value}');
  }
  stdout.writeln('unmatched: ${result.unmatched.length}');
}
