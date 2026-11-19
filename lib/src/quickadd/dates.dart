// Date and time phrase grammar and resolver for quick add. Pure: the result
// depends only on the tokens, the reference date/time and the vocabularies
// passed in. Ported from web/src/lib/nlp/dates.ts (OpenTodo v1.5.0).
import 'rule.dart' show nthWeekdayDate;
import 'tokenize.dart';
import 'vocab/index.dart';

class DateContext {
  const DateContext({
    required this.today,
    this.now,
    required this.vocabs,
    required this.dayMonthOrder,
    this.weekStart,
  });

  /// Reference local calendar date, YYYY-MM-DD.
  final String today;

  /// Reference wall-clock time, HH:MM; only "in N hours" needs it.
  final String? now;

  final List<Vocabulary> vocabs;
  final DayMonthOrder dayMonthOrder;

  /// First day of the week, 0 = Sunday … 6 = Saturday; Monday when absent.
  final int? weekStart;
}

/// A phrase match over the token range [from, to).
class DateMatch {
  const DateMatch({required this.date, required this.from, required this.to, this.bare = false});

  final String date;
  final int from;
  final int to;

  /// A month name alone ("September"): a later complete date phrase replaces it.
  final bool bare;

  DateMatch withBare(bool value) => DateMatch(date: date, from: from, to: to, bare: value);
}

class TimeMatch {
  const TimeMatch({required this.time, this.date, required this.from, required this.to});

  final String time;

  /// Set when the phrase also fixes the day ("in 3 hours" past midnight).
  final String? date;

  final int from;
  final int to;
}

// ---------- calendar helpers (local, string based, deterministic) ----------

String _pad2(int n) => n.toString().padLeft(2, '0');

String toISO(int y, int m, int d) {
  // DateTime normalises overflow (Feb 30 → Mar 2), which is what the relative
  // arithmetic wants; callers that need validation use isValidDate.
  final dt = DateTime(y, m, d);
  return '${dt.year.toString().padLeft(4, '0')}-${_pad2(dt.month)}-${_pad2(dt.day)}';
}

List<int> fromISO(String iso) {
  final p = iso.split('-');
  return [int.parse(p[0]), int.parse(p[1]), int.parse(p[2])];
}

String addDays(String iso, int n) {
  final p = fromISO(iso);
  return toISO(p[0], p[1], p[2] + n);
}

int daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

bool isValidDate(int y, int m, int d) => m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m);

/// Same day N months later, clamped to the end of the target month.
String addMonths(String iso, int n) {
  final p = fromISO(iso);
  final total = p[0] * 12 + (p[1] - 1) + n;
  final ny = (total - total % 12) ~/ 12;
  final nm = (total % 12) + 1;
  final d = p[2];
  final len = daysInMonth(ny, nm);
  return toISO(ny, nm, d < len ? d : len);
}

/// 0 = Monday … 6 = Sunday.
int weekdayIndex(String iso) {
  final p = fromISO(iso);
  return DateTime(p[0], p[1], p[2]).weekday - 1;
}

/// The next occurrence of a weekday strictly after today.
String nextWeekday(String today, int wd) {
  final delta = ((wd - weekdayIndex(today) + 7) % 7);
  return addDays(today, delta == 0 ? 7 : delta);
}

/// Days since the first day of the week containing `iso`; `weekStart` is the
/// user's first day (0 = Sunday … 6 = Saturday), Monday by default.
int daysIntoWeek(String iso, [int weekStart = 1]) {
  final p = fromISO(iso);
  final jsDay = DateTime(p[0], p[1], p[2]).weekday % 7; // 0 = Sunday
  return (jsDay - weekStart + 7) % 7;
}

/// "next [weekday]": the bare weekday, unless that still falls in the current
/// week (starting on `weekStart`), in which case the one a week later.
String nextNextWeekday(String today, int wd, [int weekStart = 1]) {
  final bare = nextWeekday(today, wd);
  final lastDay = addDays(today, 6 - daysIntoWeek(today, weekStart));
  return bare.compareTo(lastDay) <= 0 ? addDays(bare, 7) : bare;
}

/// First day of the following week (Monday unless `weekStart` says otherwise).
String startOfNextWeek(String today, [int weekStart = 1]) => addDays(today, 7 - daysIntoWeek(today, weekStart));

/// First day of the following month.
String startOfNextMonth(String today) {
  final p = fromISO(today);
  return toISO(p[0], p[1] + 1, 1);
}

/// The first date on or after today with this month and day (Feb 29 skips to a
/// leap year).
String? nextOccurrence(String today, int month, int day) {
  final y = fromISO(today)[0];
  for (var year = y; year <= y + 8; year++) {
    if (!isValidDate(year, month, day)) continue;
    final iso = toISO(year, month, day);
    if (iso.compareTo(today) >= 0) return iso;
  }
  return null;
}

String clock(int h, int m) => '${_pad2(h)}:${_pad2(m)}';

// ---------- phrase matching ----------

final Map<String, List<List<String>>> _normalizedPhrases = {};

/// Normalised word lists for a vocabulary phrase list, memoised per list key.
List<List<String>> _phrases(List<String> list, String key) => _normalizedPhrases.putIfAbsent(
      key,
      () => list
          .map((p) => normalize(p).split(' ').where((w) => w.isNotEmpty).toList())
          .toList(),
    );

/// A token at `i`, or null outside the list (the TS original reads `undefined`).
Token? _tok(List<Token> tokens, int i) => i >= 0 && i < tokens.length ? tokens[i] : null;

bool _wordMatches(Token? token, String word) {
  if (token == null || token.quoted) return false;
  if (token.norm == word) return true;
  // "wed." matches "wed"; but "mi" never matches "mi." (two-letter German abbreviations).
  return !word.endsWith('.') && token.norm.endsWith('.') && token.norm.substring(0, token.norm.length - 1) == word;
}

/// Number of tokens at `i` consumed by the longest phrase in `list`, or 0. The
/// `key` identifies the list for the normalisation cache (vocab code + field).
int phraseAt(List<Token> tokens, int i, List<String> list, String key) {
  var best = 0;
  for (final words in _phrases(list, key)) {
    if (words.length <= best || words.isEmpty) continue;
    var ok = true;
    for (var k = 0; k < words.length; k++) {
      if (!_wordMatches(_tok(tokens, i + k), words[k])) {
        ok = false;
        break;
      }
    }
    if (ok) best = words.length;
  }
  return best;
}

/// Longest-matching entry of a phrase → value map, with the value.
({int n, T value})? lookupAt<T>(List<Token> tokens, int i, Map<String, T> map, String key) {
  ({int n, T value})? best;
  for (final entry in map.entries) {
    final n = phraseAt(tokens, i, [entry.key], '$key:${entry.key}');
    if (n > (best?.n ?? 0)) best = (n: n, value: entry.value);
  }
  return best;
}

int weekdayAt(List<Token> tokens, int i, Vocabulary v) {
  for (var wd = 0; wd < 7; wd++) {
    if (phraseAt(tokens, i, v.weekdays[wd], '${v.code}:wd$wd') > 0) return _guardedAt(tokens, i, v) ? -1 : wd;
  }
  return -1;
}

final RegExp _commaEnd = RegExp(r',$');
final RegExp _commaOrSemicolonEnd = RegExp(r'[,;]$');

/// A guarded weekday abbreviation (Dutch "ma", "zo") without a date context: it is
/// a weekday only after a word such as "op", "elke" or "volgende", or before a day
/// and month ("ma 3 mrt"), a numeric date or a time ("ma om 9 uur", "ma 9:00").
bool _guardedAt(List<Token> tokens, int i, Vocabulary v) {
  final t = _tok(tokens, i);
  if (t == null) return false;
  if (v.guardedAbbreviations.isEmpty || phraseAt(tokens, i, v.guardedAbbreviations, '${v.code}:guard') == 0) {
    return false;
  }
  final lead = [...v.before, ...v.every, ...v.nextBefore, ...v.thisBefore];
  if (i > 0 && phraseAt(tokens, i - 1, lead, '${v.code}:guardlead') == 1) return false;
  // The next weekday of a list: "elke ma en wo", "op ma, wo".
  if (i > 0 && _commaEnd.hasMatch(_tok(tokens, i - 1)!.text) && weekdayAt(tokens, i - 1, v) >= 0) return false;
  if (i > 1 &&
      phraseAt(tokens, i - 1, v.andWords, '${v.code}:and') == 1 &&
      weekdayAt(tokens, i - 2, v) >= 0) {
    return false;
  }
  final next = _tok(tokens, i + 1);
  if (next == null || next.quoted || _commaOrSemicolonEnd.hasMatch(t.text)) return true;
  if (dayNumber(next) != 0 && monthAt(tokens, i + 2, v, true) != 0) return false;
  if (numericDateRe.hasMatch(next.norm) || hmRe.hasMatch(next.norm)) return false;
  final at = phraseAt(tokens, i + 1, v.atWords, '${v.code}:at');
  if (at == 0) return true;
  final k = i + 1 + at + phraseAt(tokens, i + 1 + at, v.halfWords, '${v.code}:half');
  return !RegExp(r'^\d{1,2}([:.]\d{2})?$').hasMatch(_tok(tokens, k)?.norm ?? '');
}

/// Month index (1–12) of a token; abbreviations only when `allowAbbr`.
int monthAt(List<Token> tokens, int i, Vocabulary v, bool allowAbbr) {
  for (var m = 0; m < 12; m++) {
    final mv = v.months[m];
    if (phraseAt(tokens, i, mv.names, '${v.code}:mn$m') > 0) return m + 1;
    if (allowAbbr && phraseAt(tokens, i, mv.abbr, '${v.code}:ma$m') > 0) return m + 1;
  }
  return 0;
}

final RegExp dayRe = RegExp(r'^(\d{1,2})(?:st|nd|rd|th|er|o|a|º|°|ª|\.)?$');
final RegExp _yearRe = RegExp(r'^(\d{4})$');

int dayNumber(Token? token) {
  if (token == null || token.quoted) return 0;
  final m = dayRe.firstMatch(token.norm);
  if (m == null) return 0;
  final d = int.parse(m[1]!);
  return d >= 1 && d <= 31 ? d : 0;
}

int _yearAt(Token? token) {
  if (token == null || token.quoted) return 0;
  final m = _yearRe.firstMatch(token.norm);
  return m == null ? 0 : int.parse(m[1]!);
}

({int n, int count})? countAt(List<Token> tokens, int i, Vocabulary v) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  if (RegExp(r'^\d{1,3}$').hasMatch(t.norm)) return (n: 1, count: int.parse(t.norm));
  final one = phraseAt(tokens, i, v.oneWords, '${v.code}:one');
  return one != 0 ? (n: one, count: 1) : null;
}

({int n, String unit})? _unitAt(List<Token> tokens, int i, Vocabulary v) {
  for (final unit in ['minute', 'hour', 'day', 'week', 'month', 'year']) {
    final n = phraseAt(tokens, i, v.units[unit], '${v.code}:unit:$unit');
    if (n != 0) return (n: n, unit: unit);
  }
  return null;
}

/// The compact unit suffix of "in 4m", "in 2h", "in 3d", "in 2w", "in 3mt", "in 1y".
/// A bare `m` is minutes; months are `mt`, `mth` or `mo`. Language independent, like
/// the `+30m` duration tokens.
final RegExp _compactRe = RegExp(r'^(\d{1,3})(mins?|m|hrs?|h|d|wks?|w|mths?|mt|mos?|yrs?|y)$');

const Map<String, String> _compactUnits = {
  'm': 'minute',
  'min': 'minute',
  'mins': 'minute',
  'h': 'hour',
  'hr': 'hour',
  'hrs': 'hour',
  'd': 'day',
  'w': 'week',
  'wk': 'week',
  'wks': 'week',
  'mt': 'month',
  'mth': 'month',
  'mths': 'month',
  'mo': 'month',
  'mos': 'month',
  'y': 'year',
  'yr': 'year',
  'yrs': 'year',
};

/// "in N `<unit>`" at token i: the spoken form ("in 4 minutes", "in a week") or the
/// compact one ("in 4m", "in 3d"). `n` counts the tokens, the "in" word included.
({int n, int count, String unit})? _relativeAt(List<Token> tokens, int i, Vocabulary v) {
  final inN = phraseAt(tokens, i, v.inWords, '${v.code}:in');
  if (inN == 0) return null;
  final t = _tok(tokens, i + inN);
  if (t != null && !t.quoted) {
    final m = _compactRe.firstMatch(t.norm);
    if (m != null) return (n: inN + 1, count: int.parse(m[1]!), unit: _compactUnits[m[2]!]!);
  }
  final count = countAt(tokens, i + inN, v);
  if (count == null) return null;
  final unit = _unitAt(tokens, i + inN + count.n, v);
  if (unit == null) return null;
  return (n: inN + count.n + unit.n, count: count.count, unit: unit.unit);
}

// ---------- dates ----------

/// Tokens at `i` consumed by the longest phrase of a vocabulary word list in any
/// active language, or 0.
int wordsAt(List<Token> tokens, int i, DateContext ctx, String field) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return 0;
  var best = 0;
  for (final v in ctx.vocabs) {
    final n = phraseAt(tokens, i, v.listFor(field), '${v.code}:$field');
    if (n > best) best = n;
  }
  return best;
}

/// A time sector phrase at `i` (time-sectors D8): the longest in any active
/// language, with the sector word it means, or null.
({int n, String word})? sectorPhraseAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  ({int n, String word})? best;
  for (final v in ctx.vocabs) {
    for (final entry in v.sectorPhrases.entries) {
      final n = phraseAt(tokens, i, entry.value, '${v.code}:sector:${entry.key}');
      if (n != 0 && (best == null || n > best.n)) best = (n: n, word: entry.key);
    }
  }
  return best;
}

/// A part word at `i` ("morning" after "tomorrow", day-parts D5): the longest in
/// any active language, or null.
({int n, String part})? partWordAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  ({int n, String part})? best;
  for (final v in ctx.vocabs) {
    for (final part in ['morning', 'afternoon', 'evening']) {
      final n = phraseAt(tokens, i, v.partWords[part] ?? const [], '${v.code}:part:$part');
      if (n > (best?.n ?? 0)) best = (n: n, part: part);
    }
  }
  return best;
}

/// A deadline phrase at `i`: a deadline word directly followed by a date phrase,
/// or a "by" word followed by a date phrase with no time after it.
DateMatch? matchDeadlineAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  DateMatch? best;
  for (final v in ctx.vocabs) {
    for (final by in [false, true]) {
      final n = by
          ? phraseAt(tokens, i, v.byWords, '${v.code}:by')
          : phraseAt(tokens, i, v.deadlineWords, '${v.code}:deadline');
      if (n == 0) continue;
      final dm = matchDateAt(tokens, i + n, ctx);
      // "by friday 5pm" has a time a deadline cannot hold: it stays a due date.
      if (dm == null || (by && matchTimeAt(tokens, dm.to, ctx) != null)) continue;
      if (best == null || dm.to > best.to) best = DateMatch(date: dm.date, from: i, to: dm.to);
    }
  }
  return best;
}

/// A "by" word followed by a time ("by 5pm"): a due time, the word removed with it.
TimeMatch? matchByTimeAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  TimeMatch? best;
  for (final v in ctx.vocabs) {
    final n = phraseAt(tokens, i, v.byWords, '${v.code}:by');
    final tm = n != 0 ? matchTimeAt(tokens, i + n, ctx) : null;
    if (tm != null && (best == null || tm.to > best.to)) {
      best = TimeMatch(time: tm.time, date: tm.date, from: i, to: tm.to);
    }
  }
  return best;
}

DateMatch? matchDateAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  DateMatch? best;
  void consider(DateMatch? m) {
    if (m != null && (best == null || m.to > best!.to)) best = m;
  }

  for (final v in ctx.vocabs) {
    final dayWord = _dayWordAt(tokens, i, v, ctx);
    if (dayWord != null) consider(DateMatch(date: dayWord.date, from: i, to: dayWord.n + i));
    // Optional leading preposition / article ("on", "am", "le"), only with a phrase after it.
    final pre = phraseAt(tokens, i, v.before, '${v.code}:before');
    for (final j in pre != 0 ? [i + pre, i] : [i]) {
      DateMatch wrap(({String date, int n})? m, [int skip = 0]) =>
          DateMatch(date: m!.date, from: i, to: j + skip + m.n);
      final wdp = _weekdayPhraseAt(tokens, j, v, ctx);
      if (wdp != null) consider(wrap(wdp));
      // A weekday alone before a full date names that date ("ma 1 mrt", "Monday, March 3").
      if (wdp != null && wdp.n == 1) {
        final full = _fullDateAt(tokens, j + 1, v, ctx);
        if (full != null) consider(wrap(full, 1));
      }
      final ord = _ordinalWeekdayAt(tokens, j, v, ctx);
      if (ord != null) consider(wrap(ord));
      final next = _nextPeriodAt(tokens, j, v, ctx);
      if (next != null) consider(wrap(next));
      final inP = _inPeriodAt(tokens, j, v, ctx);
      if (inP != null) consider(wrap(inP));
      final md = _monthDayAt(tokens, j, v, ctx);
      // A month name alone is a weak date, and none at all right after "from",
      // "since", "of", "for" ("invoices from September", D2).
      if (md != null && md.n == 1 && !(j == i && _monthTextBefore(tokens, i, ctx))) {
        consider(wrap(md).withBare(true));
      } else if (md != null && md.n > 1) {
        consider(wrap(md));
      }
      final num = _numericDateAt(tokens, j, ctx);
      if (num != null) consider(wrap(num));
    }
  }
  return best;
}

/// The token before `i` is a word after which a month name alone stays text.
bool _monthTextBefore(List<Token> tokens, int i, DateContext ctx) {
  final prev = _tok(tokens, i - 1);
  if (prev == null || prev.quoted) return false;
  return ctx.vocabs.any((v) => phraseAt(tokens, i - 1, v.monthTextBefore, '${v.code}:mtb') == 1);
}

({String date, int n})? _dayWordAt(List<Token> tokens, int i, Vocabulary v, DateContext ctx) {
  final hit = lookupAt(tokens, i, v.dayWords, '${v.code}:day');
  return hit == null ? null : (date: addDays(ctx.today, hit.value), n: hit.n);
}

({String date, int n})? _weekdayPhraseAt(List<Token> tokens, int j, Vocabulary v, DateContext ctx) {
  var k = j;
  String? qualifier;
  final nb = phraseAt(tokens, k, v.nextBefore, '${v.code}:nb');
  final tb = nb != 0 ? 0 : phraseAt(tokens, k, v.thisBefore, '${v.code}:tb');
  if (nb != 0) {
    qualifier = 'next';
    k += nb;
  } else if (tb != 0) {
    qualifier = 'this';
    k += tb;
  }
  final wd = weekdayAt(tokens, k, v);
  if (wd < 0) return null;
  k += 1;
  if (qualifier == null) {
    final na = phraseAt(tokens, k, v.nextAfter, '${v.code}:na');
    if (na != 0) {
      qualifier = 'next';
      k += na;
    }
  }
  final date = qualifier == 'next'
      ? nextNextWeekday(ctx.today, wd, ctx.weekStart ?? 1)
      : nextWeekday(ctx.today, wd);
  return (date: date, n: k - j);
}

// ---------- ordinal weekdays (quick-add-nth-weekday D1, D3) ----------

/// A number from 1 to 4 with an ordinal suffix, plus the French `e`, `ème` and
/// `re`. Used only before a weekday, so "2e" is a day number nowhere else.
final RegExp _ordinalRe = RegExp(r'^([1-4])(?:st|nd|rd|th|er|re|eme|e|o|a|º|°|ª|\.)$');

/// An ordinal directly before a weekday at token i. The value is 1–4, or -1 for
/// last. The weekday itself is not consumed.
({int n, int value})? weekdayOrdinalAt(
  List<Token> tokens,
  int i,
  Vocabulary v,
  bool Function(int k) isWeekday,
) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  // "segunda, quarta" and "3rd, Friday" are lists, not ordinal weekdays.
  bool direct(int n) => !_commaOrSemicolonEnd.hasMatch(_tok(tokens, i + n - 1)!.text) && isWeekday(i + n);
  final num = _ordinalRe.firstMatch(t.norm);
  if (num != null) return direct(1) ? (n: 1, value: int.parse(num[1]!)) : null;
  final word = lookupAt(tokens, i, v.ordinals, '${v.code}:ord');
  if (word != null && direct(word.n)) return (n: word.n, value: word.value);
  final pre = lookupAt(tokens, i, v.ordinalsBeforeWeekday, '${v.code}:ordwd');
  return pre != null && direct(pre.n) ? (n: pre.n, value: pre.value) : null;
}

/// A suffixed number above four directly before a weekday ("5th Friday"): parse()
/// keeps the two tokens literal as a unit instead of reading the weekday alone.
/// Returns the token count, or 0.
int ordinalOutOfRangeAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted || RegExp(r'^\d+$').hasMatch(t.norm) || dayNumber(t) <= 4 || _commaOrSemicolonEnd.hasMatch(t.text)) {
    return 0;
  }
  return ctx.vocabs.any((v) => weekdayAt(tokens, i + 1, v) >= 0) ? 2 : 0;
}

/// Tokens at k of an "of the month" phrase in any active language, or 0.
int ofMonthAt(List<Token> tokens, int k, DateContext ctx) {
  var n = 0;
  for (final w in ctx.vocabs) {
    final m = phraseAt(tokens, k, w.ofMonthWords, '${w.code}:ofmonth');
    if (m > n) n = m;
  }
  return n;
}

/// [article] ordinal weekday [of MONTH [YEAR] | of the month]: that weekday of
/// this month, or of the next once it has passed; with a month, this year or the
/// next; with a year, that year only.
({String date, int n})? _ordinalWeekdayAt(List<Token> tokens, int j, Vocabulary v, DateContext ctx) {
  var k = j + phraseAt(tokens, j, v.ordinalArticles, '${v.code}:ordart');
  final ord = weekdayOrdinalAt(tokens, k, v, (w) => weekdayAt(tokens, w, v) >= 0);
  if (ord == null) return null;
  k += ord.n;
  final wd = weekdayAt(tokens, k, v) + 1;
  k += 1;
  final ty = fromISO(ctx.today)[0];
  final tm = fromISO(ctx.today)[1];
  final of = phraseAt(tokens, k, v.ordinalOf, '${v.code}:ordof');
  final month = of != 0 ? monthAt(tokens, k + of, v, true) : 0;
  if (month != 0) {
    k += of + 1;
    final year = _yearAt(_tok(tokens, k));
    if (year != 0) return (date: nthWeekdayDate(year, month, ord.value, wd), n: k + 1 - j);
    final date = nthWeekdayDate(ty, month, ord.value, wd);
    return (
      date: date.compareTo(ctx.today) >= 0 ? date : nthWeekdayDate(ty + 1, month, ord.value, wd),
      n: k - j,
    );
  }
  k += ofMonthAt(tokens, k, ctx);
  final date = nthWeekdayDate(ty, tm, ord.value, wd);
  if (date.compareTo(ctx.today) >= 0) return (date: date, n: k - j);
  return (
    date: tm == 12 ? nthWeekdayDate(ty + 1, 1, ord.value, wd) : nthWeekdayDate(ty, tm + 1, ord.value, wd),
    n: k - j,
  );
}

({String date, int n})? _nextPeriodAt(List<Token> tokens, int j, Vocabulary v, DateContext ctx) {
  var k = j;
  final nb = phraseAt(tokens, k, v.nextBefore, '${v.code}:nb');
  k += nb;
  final unit = _unitAt(tokens, k, v);
  if (unit == null || (unit.unit != 'week' && unit.unit != 'month')) return null;
  k += unit.n;
  if (nb == 0) {
    final na = phraseAt(tokens, k, v.nextAfter, '${v.code}:na');
    if (na == 0) return null;
    k += na;
  }
  return (
    date: unit.unit == 'week' ? startOfNextWeek(ctx.today, ctx.weekStart ?? 1) : startOfNextMonth(ctx.today),
    n: k - j,
  );
}

({String date, int n})? _inPeriodAt(List<Token> tokens, int j, Vocabulary v, DateContext ctx) {
  final rel = _relativeAt(tokens, j, v);
  if (rel == null) return null;
  switch (rel.unit) {
    case 'day':
      return (date: addDays(ctx.today, rel.count), n: rel.n);
    case 'week':
      return (date: addDays(ctx.today, 7 * rel.count), n: rel.n);
    case 'month':
      return (date: addMonths(ctx.today, rel.count), n: rel.n);
    case 'year':
      return (date: addMonths(ctx.today, 12 * rel.count), n: rel.n);
  }
  // Minutes and hours are a time, read by matchTimeAt.
  return null;
}

({String date, int n})? _monthDayAt(List<Token> tokens, int j, Vocabulary v, DateContext ctx) {
  // D [of] MONTH [YEAR]
  final d1 = dayNumber(_tok(tokens, j));
  if (d1 != 0) {
    var k = j + 1;
    k += phraseAt(tokens, k, v.ofWords, '${v.code}:of');
    final m = monthAt(tokens, k, v, true);
    if (m != 0) {
      k += 1;
      final y = _yearAt(_tok(tokens, k));
      if (y != 0) k += 1;
      final date = _resolveMonthDay(ctx.today, y, m, d1);
      return date == null ? null : (date: date, n: k - j);
    }
  }
  // MONTH D [YEAR]  |  MONTH (full name alone → the 1st)
  final mAbbr = monthAt(tokens, j, v, true);
  if (mAbbr != 0) {
    final d2 = dayNumber(_tok(tokens, j + 1));
    if (d2 != 0) {
      var k = j + 2;
      final y = _yearAt(_tok(tokens, k));
      if (y != 0) k += 1;
      final date = _resolveMonthDay(ctx.today, y, mAbbr, d2);
      return date == null ? null : (date: date, n: k - j);
    }
    final mFull = monthAt(tokens, j, v, false);
    if (mFull != 0) {
      final date = _resolveMonthDay(ctx.today, 0, mFull, 1);
      return date == null ? null : (date: date, n: 1);
    }
  }
  return null;
}

/// A day and month ("1 mrt", "March 3", with a year or not) or a numeric date at
/// j; a month alone is not one.
({String date, int n})? _fullDateAt(List<Token> tokens, int j, Vocabulary v, DateContext ctx) {
  final md = _monthDayAt(tokens, j, v, ctx);
  return md != null && md.n > 1 ? md : _numericDateAt(tokens, j, ctx);
}

String? _resolveMonthDay(String today, int year, int month, int day) {
  if (year != 0) return isValidDate(year, month, day) ? toISO(year, month, day) : null;
  return nextOccurrence(today, month, day);
}

final RegExp numericDateRe = RegExp(r'^(\d{1,2})([/.-])(\d{1,2})(?:\2(\d{2}|\d{4}))?\.?$');
final RegExp _isoRe = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$');

({String date, int n})? _numericDateAt(List<Token> tokens, int j, DateContext ctx) {
  final t = _tok(tokens, j);
  if (t == null || t.quoted) return null;
  final iso = _isoRe.firstMatch(t.norm);
  if (iso != null) {
    final y = int.parse(iso[1]!), m = int.parse(iso[2]!), d = int.parse(iso[3]!);
    return isValidDate(y, m, d) ? (date: toISO(y, m, d), n: 1) : null;
  }
  final m = numericDateRe.firstMatch(t.norm);
  if (m == null) return null;
  final dotted = m[2] == '.';
  // A trailing dot only belongs to the German "12.11." form.
  if (t.norm.endsWith('.') && !dotted) return null;
  // "9.30" is a time or a number in month/day locales; dotted dates are D.M only.
  if (dotted && ctx.dayMonthOrder != DayMonthOrder.dm) return null;
  final a = int.parse(m[1]!);
  final b = int.parse(m[3]!);
  var year = m[4] == null ? 0 : int.parse(m[4]!);
  if (year != 0 && year < 100) year += 2000;
  var day = ctx.dayMonthOrder == DayMonthOrder.dm ? a : b;
  var month = ctx.dayMonthOrder == DayMonthOrder.dm ? b : a;
  final probeYear = year != 0 ? year : fromISO(ctx.today)[0];
  // "25/12" in a M/D locale can only mean 25 December; dotted forms are never swapped.
  if (!dotted && !isValidDate(probeYear, month, day) && isValidDate(probeYear, day, month)) {
    final swap = day;
    day = month;
    month = swap;
  }
  final date = _resolveMonthDay(ctx.today, year, month, day);
  return date == null ? null : (date: date, n: 1);
}

// ---------- times ----------

/// Longest time phrase at token `i`: an optional "at" word followed by a clock
/// time in 24-hour ("16:30", "15h30", "15 Uhr", "at 3"), 12-hour ("3pm", "3:30 pm")
/// or named ("noon") form, or "in N hours" relative to `now`.
TimeMatch? matchTimeAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  TimeMatch? best;
  void consider(TimeMatch? m) {
    if (m != null && (best == null || m.to > best!.to)) best = m;
  }

  final anyHourSuffix = ctx.vocabs.any((v) => v.hourSuffixH);
  for (final v in ctx.vocabs) {
    consider(_inHoursAt(tokens, i, v, ctx));
    final at = phraseAt(tokens, i, v.atWords, '${v.code}:at');
    final j = i + at;
    final named = lookupAt(tokens, j, v.timeWords, '${v.code}:tw');
    if (named != null) consider(TimeMatch(time: named.value, from: i, to: j + named.n));
    final c = _clockAt(tokens, j, v, afterAt: at != 0, hourSuffix: anyHourSuffix);
    if (c != null) consider(TimeMatch(time: c.time, from: i, to: j + c.n));
  }
  return best;
}

/// "in 4 minutes", "in 4m", "in 3 hours", "in 2h": the wall clock now plus the
/// amount, on the day it lands on.
TimeMatch? _inHoursAt(List<Token> tokens, int i, Vocabulary v, DateContext ctx) {
  if (ctx.now == null) return null;
  final rel = _relativeAt(tokens, i, v);
  if (rel == null || (rel.unit != 'hour' && rel.unit != 'minute')) return null;
  final hm = ctx.now!.split(':').map(int.parse).toList();
  final total = hm[0] * 60 + hm[1] + rel.count * (rel.unit == 'hour' ? 60 : 1);
  final within = total % 1440;
  return TimeMatch(
    time: clock(within ~/ 60, within % 60),
    date: addDays(ctx.today, total ~/ 1440),
    from: i,
    to: i + rel.n,
  );
}

final RegExp hmRe = RegExp(r'^(\d{1,2}):(\d{2})(am|pm|a\.m\.|p\.m\.)?$');
final RegExp _hDotMRe = RegExp(r'^(\d{1,2})\.(\d{2})$');
final RegExp _h12Re = RegExp(r'^(\d{1,2})(am|pm|a\.m\.|p\.m\.)$');
final RegExp _hhRe = RegExp(r'^(\d{1,2})h(\d{2})?$');
final RegExp _hRe = RegExp(r'^(\d{1,2})$');

({int n, bool pm})? _meridiem(List<Token> tokens, int k, Vocabulary v) {
  final pm = phraseAt(tokens, k, v.pm, '${v.code}:pm');
  if (pm != 0) return (n: pm, pm: true);
  final am = phraseAt(tokens, k, v.am, '${v.code}:am');
  return am != 0 ? (n: am, pm: false) : null;
}

/// "half 4" (Dutch "om half 4"): half an hour before the hour, 03:30, or 15:30
/// with a pm word after it ("'s middags"). Only after an "at" word or before an
/// am or pm word.
({String time, int n})? _halfAt(List<Token> tokens, int j, Vocabulary v, bool afterAt) {
  final half = phraseAt(tokens, j, v.halfWords, '${v.code}:half');
  final t = _tok(tokens, j + half);
  if (half == 0 || t == null || t.quoted || !_hRe.hasMatch(t.norm)) return null;
  final h = int.parse(t.norm);
  final ampm = _meridiem(tokens, j + half + 1, v);
  if (ampm != null) {
    if (h < 1 || h > 12) return null;
    return (time: clock(_to24(h == 1 ? 12 : h - 1, ampm.pm), 30), n: half + 1 + ampm.n);
  }
  if (!afterAt || h < 1 || h > 24) return null;
  return (time: clock(h - 1, 30), n: half + 1);
}

int _to24(int h, bool pm) {
  if (h == 12) return pm ? 12 : 0;
  return pm ? h + 12 : h;
}

({String time, int n})? _clockAt(
  List<Token> tokens,
  int j,
  Vocabulary v, {
  required bool afterAt,
  required bool hourSuffix,
}) {
  final t = _tok(tokens, j);
  if (t == null || t.quoted) return null;
  final half = _halfAt(tokens, j, v, afterAt);
  if (half != null) return half;
  final s = t.norm;
  int hourWord(int k) => phraseAt(tokens, k, v.hourWords, '${v.code}:hw');

  final m1 = hmRe.firstMatch(s);
  if (m1 != null) {
    final h = int.parse(m1[1]!);
    final min = int.parse(m1[2]!);
    if (min > 59) return null;
    final ampm = m1[3] != null ? (n: 0, pm: m1[3]!.startsWith('p')) : _meridiem(tokens, j + 1, v);
    if (ampm != null) {
      if (h < 1 || h > 12) return null;
      return (time: clock(_to24(h, ampm.pm), min), n: 1 + ampm.n);
    }
    if (h > 23) return null;
    return (time: clock(h, min), n: 1 + hourWord(j + 1));
  }
  final m2 = _hDotMRe.firstMatch(s);
  if (m2 != null) {
    final h = int.parse(m2[1]!);
    final min = int.parse(m2[2]!);
    final hw = hourWord(j + 1);
    if ((!afterAt && hw == 0) || h > 23 || min > 59) return null;
    return (time: clock(h, min), n: 1 + hw);
  }
  final m3 = _h12Re.firstMatch(s);
  if (m3 != null) {
    final h = int.parse(m3[1]!);
    if (h < 1 || h > 12) return null;
    return (time: clock(_to24(h, m3[2]!.startsWith('p')), 0), n: 1);
  }
  final m4 = _hhRe.firstMatch(s);
  if (m4 != null) {
    final h = int.parse(m4[1]!);
    final min = m4[2] == null ? 0 : int.parse(m4[2]!);
    if (h > 23 || min > 59) return null;
    if (m4[2] == null && !afterAt && !hourSuffix) return null;
    return (time: clock(h, min), n: 1);
  }
  final m5 = _hRe.firstMatch(s);
  if (m5 != null) {
    final h = int.parse(m5[1]!);
    final ampm = _meridiem(tokens, j + 1, v);
    if (ampm != null) {
      if (h < 1 || h > 12) return null;
      return (time: clock(_to24(h, ampm.pm), 0), n: 1 + ampm.n);
    }
    final hw = hourWord(j + 1);
    // "3 uur 's middags": an am or pm word after the hour word.
    final late = hw != 0 ? _meridiem(tokens, j + 1 + hw, v) : null;
    if (late != null && h >= 1 && h <= 12) return (time: clock(_to24(h, late.pm), 0), n: 1 + hw + late.n);
    if ((!afterAt && hw == 0) || h > 23) return null;
    return (time: clock(h, 0), n: 1 + hw);
  }
  return null;
}
