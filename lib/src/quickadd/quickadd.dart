// Glue between parse() and the quick-add input: the one public entry point of the
// port, plus the Backspace/dismissal bookkeeping. Ported from
// web/src/lib/nlp/quickadd.ts (OpenTodo v1.5.0).
import 'attributes.dart';
import 'parse.dart';
import 'reminders.dart';
import 'settings.dart' show formatMinutes;
import 'tokenize.dart';
import 'types.dart';
import 'vocab/index.dart';

/// The slice of a label the resolver needs.
class LabelRef {
  const LabelRef({
    required this.id,
    required this.name,
    this.color,
    this.position = 0,
    this.createdAt = 0,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String? color;
  final int position;
  final int createdAt;
  final int? deletedAt;
}

/// Same key as `labelKey` in web/src/lib/labels.ts: names are unique ignoring case
/// and surrounding space.
String labelNameKey(String name) => name.trim().toLowerCase();

int _compareLabels(LabelRef a, LabelRef b) {
  final byPosition = a.position - b.position;
  if (byPosition != 0) return byPosition;
  final byCreated = a.createdAt - b.createdAt;
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

/// The existing, non-deleted label a typed `@name` refers to, ignoring case. If
/// sync produced two labels with the same name, the first in sidebar order
/// (position, created_at, id) wins, so every device resolves the same id.
LabelRef? findLabel(String name, List<LabelRef> labels) {
  final key = labelNameKey(name);
  if (key.isEmpty) return null;
  final live = labels.where((l) => l.deletedAt == null);
  // Exactly the name first; then the name with spaces, dashes and underscores
  // folded, so `@deep-work` finds "deep work" (smart-title-tokens D2).
  String fold(String s) => labelNameKey(s).replaceAll(RegExp(r'[\s_-]+'), '');
  LabelRef? pick(bool Function(LabelRef) same) {
    LabelRef? best;
    for (final l in live) {
      if (!same(l)) continue;
      if (best == null || _compareLabels(l, best) < 0) best = l;
    }
    return best;
  }

  return pick((l) => labelNameKey(l.name) == key) ?? pick((l) => fold(l.name) == fold(name));
}

/// What the app gets back: the title, the task fields the line set (the shape
/// `POST /api/v1/tasks` takes) and the preview.
class QuickAddResult {
  const QuickAddResult({
    required this.title,
    required this.fields,
    required this.chips,
    required this.unmatched,
  });

  /// The title with every recognised attribute cut out.
  final String title;

  /// Only the attributes the line set explicitly, keyed as the REST body is:
  /// title, due, deadline, start, sector, evening, day_part, recurrence, reminders,
  /// project_id, labels, priority, energy, estimate_minutes, spent_minutes.
  final Map<String, Object?> fields;

  /// One chip per attribute in line order: kind, key, spans (start/end/text) and value.
  final List<Chip> chips;

  /// `#tokens` that named no project, or several; they stay in the title.
  final List<Unmatched> unmatched;
}

/// Turn a parse into `createTask` input. Each typed `@name` becomes the id of the
/// existing label with that name (ignoring case); a name with no label is created
/// once through `createLabel`. Ids keep the order typed, without duplicates.
///
/// Without `createLabel` a missing label keeps its typed name, so the caller can
/// resolve it against its own store (the web app always passes one).
Map<String, Object?> toTaskInput(
  ParseResult r, {
  List<LabelRef> labels = const [],
  String Function(String name)? createLabel,
}) {
  final out = <String, Object?>{'title': r.title};
  if (r.due != null) out['due'] = r.due!.toJson();
  if (r.deadline != null) out['deadline'] = r.deadline;
  if (r.start != null) out['start'] = r.start;
  if (r.sector != null) out['sector'] = r.sector;
  if (r.evening) {
    out['evening'] = true;
  } else if (r.dayPart != null) {
    out['day_part'] = r.dayPart;
  }
  if (r.recurrence != null) out['recurrence'] = r.recurrence;
  if (r.reminders.isNotEmpty) out['reminders'] = [for (final x in r.reminders) x.toJson()];
  if (r.projectId != null) out['project_id'] = r.projectId;
  if (r.labels.isNotEmpty) {
    final ids = <String>[];
    final created = <String, String>{};
    for (final name in r.labels) {
      final key = labelNameKey(name);
      if (key.isEmpty) continue;
      var id = findLabel(name, labels)?.id ?? created[key];
      if (id == null) {
        id = createLabel?.call(name.trim()) ?? name.trim();
        created[key] = id;
      }
      if (!ids.contains(id)) ids.add(id);
    }
    if (ids.isNotEmpty) out['labels'] = ids;
  }
  if (r.priority != null) out['priority'] = r.priority;
  if (r.energy != null) out['energy'] = r.energy;
  if (r.estimateMinutes != null) out['estimate_minutes'] = r.estimateMinutes;
  if (r.spentMinutes != null) out['spent_minutes'] = r.spentMinutes;
  return out;
}

/// Parse one quick-add line: the port of the web entry point (`parse` + `toTaskInput`).
///
/// [today] is the viewer's logical date (YYYY-MM-DD), [now] the wall clock (HH:MM,
/// used by "in N hours", "at 9" resolves against [today]). [language] is a BCP 47
/// tag; only the bundled ones (en, de, fr, it, es, pt, nl) are read and English is
/// always active. Pass [languages] to parse several at once, like the web app does.
QuickAddResult parseQuickAdd(
  String line, {
  required String today,
  required String now,
  String language = 'en',
  List<String>? languages,
  List<ProjectRef> projects = const [],
  List<Span> dismissed = const [],
  DayMonthOrder? dayMonthOrder,
  int weekStart = 1,
  bool dayParts = false,
  bool energy = false,
  bool sectors = false,
  List<LabelRef> labels = const [],
  String Function(String name)? createLabel,
}) {
  final result = parse(
    line,
    ParseContext(
      today: today,
      now: now,
      languages: languages ?? [language],
      projects: projects,
      dismissed: dismissed,
      dayMonthOrder: dayMonthOrder,
      weekStart: weekStart,
      dayParts: dayParts,
      energy: energy,
      sectors: sectors,
    ),
  );
  return QuickAddResult(
    title: result.title,
    fields: toTaskInput(result, labels: labels, createLabel: createLabel),
    chips: result.chips,
    unmatched: result.unmatched,
  );
}

/// The index of the chip Backspace may highlight: the last chip, and only when its
/// text ends the line (ignoring trailing spaces) and the caret is at the very end
/// with no selection. Otherwise -1, and Backspace edits text as usual.
int chipAtCaret(List<Chip> chips, String value, int? selStart, int? selEnd) {
  if (chips.isEmpty || selStart != value.length || selEnd != value.length) return -1;
  final end = value.trimRight().length;
  var last = -1;
  var lastEnd = -1;
  for (var i = 0; i < chips.length; i++) {
    final e = chips[i].spans.map((s) => s.end).reduce((a, b) => a > b ? a : b);
    if (e > lastEnd) {
      lastEnd = e;
      last = i;
    }
  }
  return lastEnd == end ? last : -1;
}

/// Add a chip's spans to the dismissed list (deduplicated).
List<Span> dismissChip(List<Span> dismissed, Chip chip) {
  final out = [...dismissed];
  for (final s in chip.spans) {
    if (!out.any((d) => d.start == s.start && d.end == s.end && d.text == s.text)) out.add(s);
  }
  return out;
}

/// The words a chip reads in the preview. Mirrors `chipText` in
/// web/src/app/ParseChips.tsx, without its translations and long date words: the
/// app-level view can translate; this is enough to render a preview line.
String chipLabel(Chip chip, {List<ProjectRef> projects = const [], List<LabelRef> labels = const []}) {
  final value = chip.value;
  switch (chip.kind) {
    case 'due':
      final due = value as Due;
      return due.time == null ? due.date : '${due.date} ${due.time}';
    case 'deadline':
      return 'Deadline $value';
    case 'someday':
      return 'Someday';
    case 'sector':
      return '$value';
    case 'evening':
      return 'This Evening';
    case 'daypart':
      return value == 'morning' ? 'Morning' : 'Afternoon';
    case 'project':
      return '#${_projectPath(value as String, projects)}';
    case 'label':
      final found = findLabel(value as String, labels);
      return '@${found?.name ?? value}';
    case 'priority':
      return 'p$value';
    case 'estimate':
      return formatMinutes(value as int);
    case 'spent':
      final minutes = value as int;
      return 'Spent ${minutes < 60 ? '$minutes min' : formatMinutes(minutes)}';
    case 'recurrence':
      return '$value';
    case 'reminder':
      final r = value as ReminderPhrase;
      if (r.kind == 'offset') return describeOffset(r.minutes!);
      return r.date == null ? '${r.time}' : '${r.date} ${r.time}';
    case 'energy':
      final e = '$value';
      return e.isEmpty ? e : '${e[0].toUpperCase()}${e.substring(1)}';
  }
  return '$value';
}

/// Project name with its parent path for nested projects: "Work › Docs".
String _projectPath(String id, List<ProjectRef> projects) {
  final byId = {for (final p in projects) p.id: p};
  final names = <String>[];
  final seen = <String>{};
  ProjectRef? p = byId[id];
  while (p != null && !seen.contains(p.id) && names.length < 4) {
    seen.add(p.id);
    names.insert(0, p.name);
    final parentId = p.parentId;
    p = parentId == null ? null : byId[parentId];
  }
  return names.isEmpty ? '?' : names.join(' › ');
}
