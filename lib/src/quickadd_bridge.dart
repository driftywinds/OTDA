/// The bridge to the quick-add parser: the Dart port of the web app's
/// `web/src/lib/nlp` module. Parsing happens on the device, so the preview line
/// updates as you type and works offline.
library;

import 'data/models.dart';
import 'quickadd/attributes.dart';
import 'quickadd/quickadd.dart';

/// What the composer shows under the input.
class ParsedLine {
  const ParsedLine({
    required this.title,
    this.fields = const {},
    this.chips = const [],
    this.unmatched = const [],
  });

  /// The title with the recognised tokens cut out.
  final String title;

  /// The task fields the line sets, in the shape `POST /api/v1/tasks` takes.
  final Map<String, Object?> fields;

  /// Short human labels for the preview line, e.g. `tomorrow 15:00`, `p1`, `#work`.
  final List<String> chips;

  /// Tokens that looked like a reference but matched nothing, e.g. `#tga`.
  final List<String> unmatched;

  bool get isEmpty => chips.isEmpty;

  static ParsedLine plain(String line) => ParsedLine(title: line.trim());
}

List<ProjectRef> projectRefs(Iterable<Project> projects) => [
      for (final project in projects)
        ProjectRef(
          id: project.id,
          name: project.name,
          archived: project.isArchived,
          deletedAt: project.isDeleted ? 1 : null,
          parentId: project.parentId,
        ),
    ];

/// Parses one line with the app's own grammar, in the device's today and now.
ParsedLine parseLine(
  String line, {
  String? today,
  String? now,
  String language = 'en',
  Iterable<Project> projects = const [],
}) {
  final text = line.trim();
  if (text.isEmpty) return const ParsedLine(title: '');
  final refs = projectRefs(projects);
  final result = parseQuickAdd(
    text,
    today: today ?? todayString(),
    now: now ?? nowString(),
    language: language,
    projects: refs,
  );
  return ParsedLine(
    title: result.title,
    fields: result.fields,
    chips: [for (final chip in result.chips) chipLabel(chip, projects: refs)],
    unmatched: [for (final miss in result.unmatched) miss.span.text],
  );
}

String todayString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

String nowString() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}
