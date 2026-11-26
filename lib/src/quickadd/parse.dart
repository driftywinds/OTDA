// parse(line, ctx): the quick-add grammar. Pure and deterministic: the result
// depends only on the line, the reference date and time, the languages, the
// project list and the dismissed spans. No clock reads, no randomness.
// Ported from web/src/lib/nlp/parse.ts (OpenTodo v1.5.0).
import 'attributes.dart';
import 'dates.dart';
import 'recurrence.dart';
import 'reminders.dart';
import 'rule.dart' show compatibleRule, firstOccurrence;
import 'sectors.dart' show resolvePhrase;
import 'tokenize.dart';
import 'types.dart';
import 'vocab/index.dart';

/// One recognised attribute; drives a preview chip. `spans` are removed from the title.
typedef AttributeKind = String;

class Chip {
  const Chip({required this.kind, required this.key, required this.spans, required this.value, this.spanKinds});

  final AttributeKind kind;

  /// What each span is, when the chip mixes things: a `due` chip reads `date` for
  /// the day phrase and `time` for the clock phrase, so a highlighter can colour
  /// them apart. Null means every span is just [kind].
  final List<AttributeKind>? spanKinds;

  /// Stable within one parse: kind plus the first span start.
  final String key;

  final List<Span> spans;

  /// Resolved value: [Due], deadline date, project id, label name, priority,
  /// minutes, true (evening), the part (daypart), the canonical rule, a
  /// [ReminderPhrase] or the energy.
  final Object? value;
}

class ParseContext {
  const ParseContext({
    required this.today,
    this.now,
    required this.languages,
    this.projects = const [],
    this.dismissed = const [],
    this.dayMonthOrder,
    this.weekStart = 1,
    this.dayParts = false,
    this.energy = false,
    this.sectors = false,
  });

  /// Reference local date, YYYY-MM-DD (the viewer's logical today).
  final String today;

  /// Reference local wall-clock time, HH:MM; used by "in N hours".
  final String? now;

  /// Preferred languages (BCP 47 tags); filtered to bundled ones, English appended.
  final List<String> languages;

  final List<ProjectRef> projects;

  /// Spans the user rejected; skipped while the line still has the same text there.
  final List<Span> dismissed;

  /// Numeric date order; defaults to the first active language's order.
  final DayMonthOrder? dayMonthOrder;

  /// First day of the week, 0 = Sunday … 6 = Saturday; Monday when absent.
  final int weekStart;

  /// The account uses day parts (day-parts D5): the part phrases are read.
  final bool dayParts;

  /// The account offers energy (task-energy D3): the `~deep` tokens are read.
  final bool energy;

  /// The account uses time sectors (time-sectors D8).
  final bool sectors;
}

class ParseResult {
  const ParseResult({
    required this.title,
    required this.due,
    required this.deadline,
    required this.start,
    required this.sector,
    required this.evening,
    required this.dayPart,
    required this.projectId,
    required this.labels,
    required this.priority,
    required this.energy,
    required this.estimateMinutes,
    required this.spentMinutes,
    required this.recurrence,
    required this.reminders,
    required this.chips,
    required this.unmatched,
  });

  final String title;
  final Due? due;

  /// "YYYY-MM-DD" from a deadline phrase ("deadline friday"), or null.
  final String? deadline;

  /// "someday" from a someday phrase on a line without a date, or null.
  final String? start;

  /// The time sector from a sector phrase on a line without a date, or null.
  final String? sector;

  /// Set by "tonight" / "this evening", or by "evening" after a date with day parts on.
  final bool evening;

  /// Morning or Afternoon from a part phrase, only with `dayParts`; null otherwise.
  final String? dayPart;

  final String? projectId;

  final List<String> labels;
  final int? priority;

  /// Deep, Medium or Low from a `~` token, only with `energy`; the last one wins.
  final String? energy;

  final int? estimateMinutes;

  /// Minutes already spent from a `30m/2h` token (time-tracking D10).
  final int? spentMinutes;

  /// The canonical recurrence rule ("every monday"), or null.
  final String? recurrence;

  /// Reminders as typed; the caller resolves them against the final due.
  final List<ReminderPhrase> reminders;

  /// One chip per attribute in line order (one per label and per reminder).
  final List<Chip> chips;

  /// `#tokens` that name no project, or several, in line order; they stay in the title.
  final List<Unmatched> unmatched;
}

/// A `#token` that resolved to no project (smart-title-tokens D4).
class Unmatched {
  const Unmatched({required this.span, required this.reason, this.count});

  final Span span;

  /// 'none' or 'ambiguous'.
  final String reason;

  /// How many projects the prefix matches, for 'ambiguous'.
  final int? count;
}

Span _spanOf(String line, List<Token> tokens, int from, int to) {
  final start = tokens[from].start;
  final end = tokens[to - 1].end;
  return Span(start, end, line.substring(start, end));
}

/// A dismissed span still applies while the line has exactly the same text there.
List<Span> liveDismissals(String line, [List<Span> dismissed = const []]) =>
    dismissed.where((d) => d.end <= line.length && line.substring(d.start, d.end) == d.text).toList();

bool _overlaps(Span a, List<Span> list) => list.any((b) => a.start < b.end && b.start < a.end);

int _max(int a, int b) => a > b ? a : b;

/// A part word directly after a date phrase ending at token `to` (day-parts D5);
/// returns where reading goes on and the part it set.
({int next, Span? evening, ({String value, Span span})? dayPart}) _partAfter(
  String line,
  List<Token> tokens,
  int to,
  ParseContext ctx,
  DateContext dctx,
  List<Span> dismissed,
  Span? evening,
  ({String value, Span span})? dayPart,
) {
  if (!ctx.dayParts || evening != null || dayPart != null) return (next: to, evening: evening, dayPart: dayPart);
  final pw = partWordAt(tokens, to, dctx);
  final span = pw != null ? _spanOf(line, tokens, to, to + pw.n) : null;
  if (pw == null || span == null || _overlaps(span, dismissed)) return (next: to, evening: evening, dayPart: dayPart);
  if (pw.part == 'evening') return (next: to + pw.n, evening: span, dayPart: dayPart);
  return (next: to + pw.n, evening: evening, dayPart: (value: pw.part, span: span));
}

/// A time sector phrase read on a line: the sector it means on the line's day, its
/// span and its length in tokens.
class _SectorHit {
  const _SectorHit(this.value, this.span, this.n);

  final String value;
  final Span span;
  final int n;
}

/// A time sector phrase at token `i` that no dismissal covers (time-sectors D8).
_SectorHit? _sectorAt(String line, List<Token> tokens, int i, ParseContext ctx, DateContext dctx, List<Span> dismissed) {
  final sp = sectorPhraseAt(tokens, i, dctx);
  final span = sp != null ? _spanOf(line, tokens, i, i + sp.n) : null;
  if (sp == null || span == null || _overlaps(span, dismissed)) return null;
  return _SectorHit(resolvePhrase(sp.word, ctx.today, ctx.weekStart)!, span, sp.n);
}

/// JS Array.prototype.sort is stable and List.sort is not: chips keep insertion
/// order on equal starts (a due and an evening chip can share a start).
List<Chip> _sortedByStart(List<Chip> chips) {
  final indexed = [for (var i = 0; i < chips.length; i++) (index: i, chip: chips[i])];
  indexed.sort((a, b) {
    final byStart = a.chip.spans[0].start - b.chip.spans[0].start;
    return byStart != 0 ? byStart : a.index - b.index;
  });
  return [for (final e in indexed) e.chip];
}

ParseResult parse(String line, ParseContext ctx) {
  final vocabs = vocabulariesFor(ctx.languages);
  final dctx = DateContext(
    today: ctx.today,
    now: ctx.now,
    vocabs: vocabs,
    dayMonthOrder: ctx.dayMonthOrder ?? vocabs[0].dayMonthOrder,
    weekStart: ctx.weekStart,
    dashRanges: true,
  );
  final bareHourIsTime = vocabs.any((v) => v.hourSuffixH);
  final dismissed = liveDismissals(line, ctx.dismissed);
  final tokenized = tokenize(line);
  final tokens = tokenized.tokens;

  // A bare month ("September") is replaced by a later complete date phrase.
  ({String value, Span span, bool bare})? date;
  ({String value, String? date, Span span})? time;
  ({String id, Span span})? project;
  ({int value, Span span})? priority;
  ({int value, Span span})? estimate;
  int? spent;
  ({String value, Span span})? deadline;
  Span? evening;
  ({String value, Span span})? dayPart;
  // A part phrase sets one part: the evening flag or a day part, never both.

  Span? someday;
  _SectorHit? sector;
  ({String value, Span span, String? start})? recurrence;
  final reminders = <({ReminderPhrase value, Span span})>[];
  final labels = <({String value, Span span})>[];
  // Every energy token leaves the title; the last one is the value (task-energy D4).
  final energies = <({String value, Span span})>[];
  final unmatched = <Unmatched>[];

  var i = 0;
  while (i < tokens.length) {
    final tok = tokens[i];
    if (tok.quoted) {
      i++;
      continue;
    }
    final one = _spanOf(line, tokens, i, i + 1);
    final free = !_overlaps(one, dismissed);

    // Attribute tokens are single tokens and language independent.
    if (free) {
      if (project == null && tok.text.startsWith('#')) {
        final p = matchProject(tok.text, ctx.projects);
        if (p != null) {
          project = (id: p.id, span: one);
          i++;
          continue;
        }
        // A #token that names no project stays in the title; the preview says why.
        final miss = projectMiss(tok.text, ctx.projects);
        if (miss != null) {
          unmatched.add(Unmatched(span: one, reason: miss.reason, count: miss.count));
        }
      }
      final label = matchLabel(tok.text);
      if (label != null) {
        labels.add((value: label, span: one));
        i++;
        continue;
      }
      final energy = ctx.energy ? matchEnergy(tok.text) : null;
      if (energy != null) {
        energies.add((value: energy, span: one));
        i++;
        continue;
      }
      if (priority == null) {
        final p = matchPriority(tok.text);
        if (p != null) {
          priority = (value: p, span: one);
          i++;
          continue;
        }
      }
      if (estimate == null) {
        final s = matchSpent(tok.text);
        if (s != null) {
          estimate = (value: s.estimate, span: one);
          spent = s.spent;
          i++;
          continue;
        }
        final m = matchDuration(tok.text, bareHourIsTime: bareHourIsTime);
        if (m != null) {
          estimate = (value: m, span: one);
          i++;
          continue;
        }
      }
    }

    // A deadline word directly before a date phrase: the first one wins (deadlines D7).
    if (deadline == null) {
      final dl = matchDeadlineAt(tokens, i, dctx);
      final span = dl != null ? _spanOf(line, tokens, dl.from, dl.to) : null;
      if (dl != null && span != null && !_overlaps(span, dismissed)) {
        deadline = (value: dl.date, span: span);
        // A deadline has no time: a time right after it stays in the title.
        i = matchTimeAt(tokens, dl.to, dctx)?.to ?? dl.to;
        continue;
      }
    }

    // "tonight" / "this evening": due today (unless a date came first) and the
    // evening flag (someday-and-evening D6). Checked before the day words.
    if (evening == null) {
      final n = wordsAt(tokens, i, dctx, 'eveningWords');
      final span = n != 0 ? _spanOf(line, tokens, i, i + n) : null;
      if (span != null && !_overlaps(span, dismissed)) {
        evening = span;
        if (date == null || date.bare) date = (value: ctx.today, span: span, bare: false);
        i += n;
        continue;
      }
    }

    // "this morning" / "this afternoon" (day-parts D5): like "tonight", only with day parts on.
    if (ctx.dayParts && evening == null && dayPart == null) {
      var matched = false;
      for (final entry in [('morningWords', 'morning'), ('afternoonWords', 'afternoon')]) {
        final n = wordsAt(tokens, i, dctx, entry.$1);
        final span = n != 0 ? _spanOf(line, tokens, i, i + n) : null;
        if (span != null && !_overlaps(span, dismissed)) {
          dayPart = (value: entry.$2, span: span);
          if (date == null || date.bare) date = (value: ctx.today, span: span, bare: false);
          i += n;
          matched = true;
          break;
        }
      }
      if (matched) continue;
    }

    // Date, time, recurrence and reminder phrases: the longest wins, a date on a
    // tie. The first date, time and rule win; reminders accumulate. A match whose
    // range overlaps a live dismissal is ignored.
    var dm = date != null && !date.bare ? null : matchDateAt(tokens, i, dctx);
    // After a bare month only a complete date phrase counts; another bare month stays text.
    if (date != null && dm != null && dm.bare) dm = null;
    var tm = time != null ? null : (matchTimeAt(tokens, i, dctx) ?? matchByTimeAt(tokens, i, dctx));
    var rm = matchRecurrenceAt(tokens, i, dctx);
    // After the first rule only a literal match still counts (it keeps "cada 2 lunes" whole).
    if (recurrence != null && rm != null && !rm.literal) rm = null;
    if (rm == null) {
      final n = ordinalOutOfRangeAt(tokens, i, dctx);
      if (n != 0) rm = RecurrenceMatch(rule: '', from: i, to: i + n, literal: true);
    }
    var mm = matchReminderAt(tokens, i, dctx);
    final dSpan = dm != null ? _spanOf(line, tokens, dm.from, dm.to) : null;
    final tSpan = tm != null ? _spanOf(line, tokens, tm.from, tm.to) : null;
    final rSpan = rm != null ? _spanOf(line, tokens, rm.from, rm.to) : null;
    final mSpan = mm != null ? _spanOf(line, tokens, mm.from, mm.to) : null;
    if (dSpan != null && _overlaps(dSpan, dismissed)) dm = null;
    if (tSpan != null && _overlaps(tSpan, dismissed)) tm = null;
    if (rSpan != null && _overlaps(rSpan, dismissed)) rm = null;
    if (mSpan != null && _overlaps(mSpan, dismissed)) mm = null;
    final phraseEnd = _max(rm?.to ?? 0, mm?.to ?? 0);
    if (phraseEnd > _max(dm?.to ?? 0, tm?.to ?? 0)) {
      if (rm != null && rSpan != null && rm.to == phraseEnd) {
        // A literal match is skipped as a unit and stays in the title.
        if (!rm.literal) recurrence = (value: rm.rule, span: rSpan, start: rm.start);
        i = rm.to;
      } else if (mm != null && mSpan != null) {
        reminders.add((value: mm.reminder, span: mSpan));
        i = mm.to;
      }
    } else if (dm != null && dSpan != null && (tm == null || dm.to >= tm.to)) {
      date = (value: dm.date, span: dSpan, bare: dm.bare);
      final part = _partAfter(line, tokens, dm.to, ctx, dctx, dismissed, evening, dayPart);
      evening = part.evening;
      dayPart = part.dayPart;
      i = part.next;
    } else if (tm != null && tSpan != null) {
      time = (value: tm.time, date: tm.date, span: tSpan);
      i = tm.to;
    } else {
      final sm = ctx.sectors && sector == null ? _sectorAt(line, tokens, i, ctx, dctx, dismissed) : null;
      if (sm != null) {
        sector = sm;
        i += sm.n;
        continue;
      }
      // A someday phrase counts only if the line ends up without a date (below).
      final n = someday != null ? 0 : wordsAt(tokens, i, dctx, 'somedayWords');
      final span = n != 0 ? _spanOf(line, tokens, i, i + n) : null;
      if (span != null && !_overlaps(span, dismissed)) {
        someday = span;
        i += n;
      } else {
        i++;
      }
    }
  }
  // A sector phrase, like a someday phrase, counts only if the line ends up without a date.
  final sectored = sector != null && date == null && time == null && recurrence == null;
  final parked = someday != null && !sectored && date == null && time == null && deadline == null && recurrence == null;

  Due? due;
  if (date != null || time != null || recurrence != null) {
    final dueDate = date?.value ??
        (recurrence != null ? firstOccurrence(recurrence.value, recurrence.start ?? ctx.today) : (time?.date ?? ctx.today));
    due = Due(dueDate, time?.value);
    if (recurrence != null) {
      // The rule is stored in the form a 1.0 client reads when one means the same thing.
      recurrence = (value: compatibleRule(recurrence.value, dueDate), span: recurrence.span, start: recurrence.start);
    }
  }

  final chips = <Chip>[];
  void chip(AttributeKind kind, List<Span> spans, Object? value, [List<AttributeKind>? spanKinds]) =>
      chips.add(Chip(kind: kind, key: '$kind:${spans[0].start}', spans: spans, value: value, spanKinds: spanKinds));

  final dueParts = <({Span span, AttributeKind kind})>[];
  for (final part in [
    if (date != null) (span: date.span, kind: 'date'),
    if (time != null) (span: time.span, kind: 'time'),
  ]) {
    if (!dueParts.any((x) => identical(x.span, part.span))) dueParts.add(part);
  }
  dueParts.sort((a, b) => a.span.start - b.span.start);
  if (due != null && dueParts.isNotEmpty) {
    chip('due', [for (final x in dueParts) x.span], due, [for (final x in dueParts) x.kind]);
  }
  if (recurrence != null) chip('recurrence', [recurrence.span], recurrence.value);
  for (final r in reminders) {
    chip('reminder', [r.span], r.value);
  }
  if (evening != null) chip('evening', [evening], true);
  if (dayPart != null) chip('daypart', [dayPart.span], dayPart.value);
  if (parked) chip('someday', [someday], 'someday');
  if (sectored) chip('sector', [sector.span], sector.value);
  if (deadline != null) chip('deadline', [deadline.span], deadline.value);
  if (project != null) chip('project', [project.span], project.id);
  for (final l in labels) {
    chip('label', [l.span], l.value);
  }
  if (priority != null) chip('priority', [priority.span], priority.value);
  if (energies.isNotEmpty) chip('energy', [for (final e in energies) e.span], energies.last.value);
  if (estimate != null) chip('estimate', [estimate.span], estimate.value);
  // The spent chip shares the token's span: dismissing either keeps the whole token as text.
  if (estimate != null && spent != null) chip('spent', [estimate.span], spent);
  final sortedChips = _sortedByStart(chips);

  return ParseResult(
    title: stripSpans(line, [for (final c in sortedChips) ...c.spans], tokenized.quoteSpans),
    due: due,
    deadline: deadline?.value,
    start: parked ? 'someday' : null,
    sector: sectored ? sector.value : null,
    evening: evening != null,
    dayPart: dayPart?.value,
    projectId: project?.id,
    labels: [for (final l in labels) l.value],
    priority: priority?.value,
    energy: energies.isNotEmpty ? energies.last.value : null,
    estimateMinutes: estimate?.value,
    spentMinutes: spent,
    recurrence: recurrence?.value,
    reminders: [for (final r in reminders) r.value],
    chips: sortedChips,
    unmatched: unmatched,
  );
}

/// Keep dismissed spans attached to their text while the line is edited: the edit
/// is the region between the common prefix and the common suffix of the two lines.
/// Spans entirely before it stay, spans entirely after it shift by the length
/// change, and spans the edit touches are dropped (their text changed).
List<Span> rebaseDismissed(String prev, String next, List<Span> dismissed) {
  if (prev == next) return [...dismissed];
  var p = 0;
  final max = prev.length < next.length ? prev.length : next.length;
  while (p < max && prev[p] == next[p]) {
    p++;
  }
  var s = 0;
  while (s < max - p && prev[prev.length - 1 - s] == next[next.length - 1 - s]) {
    s++;
  }
  final editStart = p;
  final editEndPrev = prev.length - s;
  final delta = next.length - prev.length;
  final out = <Span>[];
  for (final d in dismissed) {
    if (d.end <= editStart) {
      out.add(d);
    } else if (d.start >= editEndPrev) {
      out.add(Span(d.start + delta, d.end + delta, d.text));
    }
  }
  // The span must still be the same whole words: "may" → "mayo" is a new word.
  bool boundary(String? ch) => ch == null || ch == ' ' || ch == '"' || RegExp(r'\s').hasMatch(ch);
  return out
      .where((d) =>
          next.substring(d.start, d.end) == d.text &&
          boundary(d.start - 1 >= 0 ? next[d.start - 1] : null) &&
          boundary(d.end < next.length ? next[d.end] : null))
      .toList();
}
