// Recurrence phrases in the quick-add line (quick-add-recurrence, design D1, D2):
// "every Monday", "jeden Montag", "tous les 3 jours après achèvement", "every 2nd
// Tuesday until 31 Dec", "daily". A phrase is translated into the canonical
// English rule of the recurring-tasks grammar and accepted only if parseRule
// accepts it, so the parser never emits a rule the server would refuse.
// Ported from web/src/lib/nlp/recurrence.ts (OpenTodo v1.5.0).
import 'dates.dart';
import 'rule.dart' show parseRule;
import 'tokenize.dart';
import 'vocab/index.dart';

class RecurrenceMatch {
  const RecurrenceMatch({
    required this.rule,
    required this.from,
    required this.to,
    this.literal = false,
    this.start,
  });

  /// The canonical rule, e.g. "every monday"; empty for a literal match.
  final String rule;

  final int from;
  final int to;

  /// A phrase the grammar cannot express that must stay in the title as a unit
  /// ("every 2 Mondays"): it wins the longest-match comparison like any match but
  /// records no attribute.
  final bool literal;

  /// The date of a start phrase next to the rule ("starting tomorrow"): the series
  /// starts on its first date on or after it.
  final String? start;
}

/// A pattern after "every"; `monthly` patterns accept the "of the month" tail.
class _Pattern {
  const _Pattern(this.n, this.pattern, this.monthly);

  final int n;
  final String pattern;
  final bool monthly;
}

const List<String> _weekdayEn = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
const Map<int, String> _ordinalEn = {1: '1st', 2: '2nd', 3: '3rd', 4: '4th', -1: 'last'};

Token? _tok(List<Token> tokens, int i) => i >= 0 && i < tokens.length ? tokens[i] : null;

({int n, String unit})? _recUnitAt(List<Token> tokens, int i, Vocabulary v) {
  for (final unit in ['day', 'week', 'month', 'year']) {
    final n = phraseAt(tokens, i, v.units[unit], '${v.code}:unit:$unit');
    if (n != 0) return (n: n, unit: unit);
  }
  return null;
}

/// Any unit word at i, including hours and minutes (a number before one is never
/// an ordinal).
bool _anyUnitAt(List<Token> tokens, int i, Vocabulary v) => ['minute', 'hour', 'day', 'week', 'month', 'year']
    .any((u) => phraseAt(tokens, i, v.units[u], '${v.code}:unit:$u') > 0);

/// A weekday at i, or its plural after "every": Romance plurals without their
/// final s ("lundis", "segundas"), hyphenated ones without the s of each part
/// ("segundas-feiras"), German ones without their final e ("Montage").
int _weekdayPluralAt(List<Token> tokens, int i, Vocabulary v) {
  final wd = weekdayAt(tokens, i, v);
  if (wd >= 0) return wd;
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return -1;
  for (final stem in _pluralStems(t.norm)) {
    final w = weekdayAt([Token(text: t.text, norm: stem, start: t.start, end: t.end, quoted: t.quoted)], 0, v);
    if (w >= 0) return w;
  }
  return -1;
}

/// Candidate singular forms of a plural weekday token.
List<String> _pluralStems(String norm) {
  final out = <String>[];
  if (norm.length >= 4 && norm.endsWith('s')) out.add(norm.substring(0, norm.length - 1));
  if (norm.length >= 6 && norm.endsWith('e')) out.add(norm.substring(0, norm.length - 1));
  if (norm.contains('-')) {
    out.add(norm.split('-').map((p) => p.endsWith('s') ? p.substring(0, p.length - 1) : p).join('-'));
  }
  return out;
}

/// An ordinal at i: a day number with a suffix ("2nd", "15.", "3º") or an ordinal word.
({int n, int value})? _ordinalAt(List<Token> tokens, int i, Vocabulary v) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  if (!RegExp(r'^\d+$').hasMatch(t.norm)) {
    final d = dayNumber(t);
    if (d != 0) return (n: 1, value: d);
  }
  final word = lookupAt(tokens, i, v.ordinals, '${v.code}:ord');
  return word == null ? null : (n: word.n, value: word.value);
}

/// The pattern after "every" at token k: [N] unit, weekday list, collective
/// weekday, ordinal forms.
_Pattern? _patternAt(List<Token> tokens, int k, Vocabulary v) {
  final all = phraseAt(tokens, k, v.weekdayAll, '${v.code}:wdall');
  if (all != 0) return _Pattern(all, 'weekday', false);
  // [N] unit, and "[N] weeks on <weekdays>" (quick-add-weekday-recurrence D1)
  final tk = _tok(tokens, k);
  final count = (tk != null && !tk.quoted && RegExp(r'^\d{1,3}$').hasMatch(tk.norm)) ? int.parse(tk.norm) : 0;
  final unit = _recUnitAt(tokens, k + (count != 0 ? 1 : 0), v);
  if (unit != null) {
    final n = (count != 0 ? 1 : 0) + unit.n;
    final pattern = count != 0 && count != 1 ? '$count ${unit.unit}s' : unit.unit;
    final on = unit.unit == 'week' ? _weeksOnAt(tokens, k + n, v) : null;
    if (on != null) return _Pattern(n + on.n, '$pattern on ${on.days}', false);
    return _Pattern(n, pattern, false);
  }
  if (count != 0 && _anyUnitAt(tokens, k + 1, v)) return null; // "every 3 hours": not expressible
  // ordinal weekday: "2nd monday", "2e lundis", "segunda segunda-feira"
  final nth = weekdayOrdinalAt(tokens, k, v, (w) => _weekdayPluralAt(tokens, w, v) >= 0);
  if (nth != null) {
    final wd = _weekdayPluralAt(tokens, k + nth.n, v);
    return _ofAMonth(tokens, k + nth.n + 1, v, _Pattern(nth.n + 1, '${_ordinalEn[nth.value]} ${_weekdayEn[wd]}', true));
  }
  // ordinal [weekday | day | weekday-collective]
  final ord = _ordinalAt(tokens, k, v);
  if (ord != null) {
    final j = k + ord.n;
    final wd = _weekdayPluralAt(tokens, j, v);
    if (wd >= 0 && ord.value <= 4) {
      return _ofAMonth(tokens, j + 1, v, _Pattern(ord.n + 1, '${_ordinalEn[ord.value]} ${_weekdayEn[wd]}', true));
    }
    // "1st weekday" … "last weekday": the n-th Monday-to-Friday day of the month.
    final wall = ord.value <= 4 ? phraseAt(tokens, j, v.weekdayAll, '${v.code}:wdall') : 0;
    if (wall != 0) return _Pattern(ord.n + wall, '${_ordinalEn[ord.value]} weekday', true);
    if (ord.value == -1) {
      final day = phraseAt(tokens, j, v.units.day, '${v.code}:unit:day');
      if (day != 0) return _Pattern(ord.n + day, 'last day', true);
      return null;
    }
    // A bare day of the month ("every 15th"); ordinal words alone mean nothing.
    if (RegExp(r'^\d').hasMatch(tk!.norm) && ord.value >= 1 && ord.value <= 31) {
      final value = ord.value;
      final suffix = value % 10 == 1 && value != 11
          ? 'st'
          : (value % 10 == 2 && value != 12 ? 'nd' : (value % 10 == 3 && value != 13 ? 'rd' : 'th'));
      return _Pattern(ord.n, '$value$suffix', true);
    }
    return null;
  }
  final list = _weekdayListAt(tokens, k, v);
  return list == null ? null : _Pattern(list.n, list.days, false);
}

const List<String> _monthEn = [
  '', 'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december',
];

/// An ordinal weekday followed by a month ("last sunday in march") is yearly:
/// `every last sunday of march`, with the same "of"/"in" words one-off dates read.
_Pattern _ofAMonth(List<Token> tokens, int k, Vocabulary v, _Pattern p) {
  final of = phraseAt(tokens, k, v.ordinalOf, '${v.code}:ordof');
  final month = of != 0 ? monthAt(tokens, k + of, v, true) : 0;
  return month != 0 ? _Pattern(p.n + of + 1, '${p.pattern} of ${_monthEn[month]}', false) : p;
}

/// A weekday list at k ("Mon, Wed and Fri") as the rule's English list, or null.
({int n, String days})? _weekdayListAt(List<Token> tokens, int k, Vocabulary v) {
  final days = <int>[];
  var j = k;
  while (true) {
    final wd = _weekdayPluralAt(tokens, j, v);
    if (wd < 0) break;
    days.add(wd);
    j += 1;
    final and = phraseAt(tokens, j, v.andWords, '${v.code}:and');
    if (and != 0 && _weekdayPluralAt(tokens, j + and, v) >= 0) {
      j += and;
      continue;
    }
    // "mon, wed": the comma was folded off by normalize; a following weekday continues the list.
    if (_tok(tokens, j - 1)!.text.endsWith(',') && _weekdayPluralAt(tokens, j, v) >= 0) continue;
    break;
  }
  return days.isNotEmpty ? (n: j - k, days: days.map((d) => _weekdayEn[d]).join(', ')) : null;
}

/// "on Saturday", "am Samstag", "le samedi" after a week count: the weekdays the
/// rule keeps.
({int n, String days})? _weeksOnAt(List<Token> tokens, int k, Vocabulary v) {
  final on = phraseAt(tokens, k, v.weekOnWords, '${v.code}:weekon');
  if (on == 0) return null;
  final list = _weekdayListAt(tokens, k + on, v);
  return list == null ? null : (n: on + list.n, days: list.days);
}

/// A bare count between the "every" word and a weekday ("every 2 Mondays"): a
/// count the grammar cannot express, so a literal match keeps it whole.
int _countWeekdayAt(List<Token> tokens, int k, Vocabulary v) {
  final t = _tok(tokens, k);
  if (t == null || t.quoted || !RegExp(r'^\d{1,3}$').hasMatch(t.norm)) return 0;
  return _weekdayPluralAt(tokens, k + 1, v) >= 0 ? 2 : 0;
}

/// "every other" with a unit or a weekday at token i: "every other week" is every
/// 2 weeks; "every other friday" is every 2 weeks on Friday. Also the French form
/// around the noun, "une semaine sur deux", "un vendredi sur deux".
({int n, String pattern})? _everyOtherAt(List<Token> tokens, int i, Vocabulary v) {
  ({int n, String pattern})? noun(int k) {
    final unit = _recUnitAt(tokens, k, v);
    if (unit != null) return (n: unit.n, pattern: '2 ${unit.unit}s');
    final wd = _weekdayPluralAt(tokens, k, v);
    if (wd >= 0) return (n: 1, pattern: '2 weeks on ${_weekdayEn[wd]}');
    return null;
  }

  final ev = phraseAt(tokens, i, v.everyOther, '${v.code}:other');
  if (ev != 0) {
    final m = noun(i + ev);
    return m == null ? null : (n: ev + m.n, pattern: m.pattern);
  }
  final pre = phraseAt(tokens, i, v.everyOtherAround.before, '${v.code}:otherb');
  if (pre == 0) return null;
  final m = noun(i + pre);
  final post = m != null ? phraseAt(tokens, i + pre + m.n, v.everyOtherAround.after, '${v.code}:othera') : 0;
  return m != null && post != 0 ? (n: pre + m.n + post, pattern: m.pattern) : null;
}

/// The longest phrase of a vocabulary list at token k across the active languages.
int _anyPhraseAt(List<Token> tokens, int k, DateContext ctx, String field) {
  var n = 0;
  for (final w in ctx.vocabs) {
    final m = phraseAt(tokens, k, w.listFor(field), '${w.code}:$field');
    if (m > n) n = m;
  }
  return n;
}

/// A start phrase at k ("starting tomorrow", "ab Montag"): its date and the token
/// after it.
({String date, int to})? _startAt(List<Token> tokens, int k, DateContext ctx) {
  final sw = _anyPhraseAt(tokens, k, ctx, 'startWords');
  final dm = sw != 0 ? matchDateAt(tokens, k + sw, ctx) : null;
  return dm == null ? null : (date: dm.date, to: dm.to);
}

/// The longest recurrence phrase at token i, with what may surround it: a
/// connector before it ("and repeat", "und dann") and a start phrase before or
/// after it ("every day from Monday"), which go with the rule only when a rule
/// follows or precedes them, so "Repeat the test" keeps its words.
RecurrenceMatch? matchRecurrenceAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  var k = i + _anyPhraseAt(tokens, i, ctx, 'repeatWords');
  final lead = _startAt(tokens, k, ctx);
  if (lead != null) k = lead.to + _anyPhraseAt(tokens, lead.to, ctx, 'repeatWords');
  if (k == i) return _ruleAt(tokens, i, ctx);
  final m = _ruleAt(tokens, k, ctx);
  if (m == null || m.literal) return _ruleAt(tokens, i, ctx);
  return RecurrenceMatch(
    rule: m.rule,
    from: i,
    to: m.to,
    literal: m.literal,
    start: lead != null && m.start == null ? lead.date : m.start,
  );
}

/// The longest rule at token i across the active vocabularies, with its optional
/// tails: of the month (after a monthly pattern), after completion, until <date
/// phrase>, for N times, and a start phrase.
RecurrenceMatch? _ruleAt(List<Token> tokens, int i, DateContext ctx) {
  final t = _tok(tokens, i);
  if (t == null || t.quoted) return null;
  RecurrenceMatch? best;
  // Tails are tried in every active language: "every monday until 31 Dec" works with any vocabulary.
  int tail(int k, String field) => _anyPhraseAt(tokens, k, ctx, field);

  /// A head (the pattern after "every", ending before token k) with its tails;
  /// kept when longer than the best so far.
  void consider(String pattern, int end) {
    var k = end;
    String? start;
    void startTail() {
      final st = start == null ? _startAt(tokens, k, ctx) : null;
      if (st != null) {
        start = st.date;
        k = st.to;
      }
    }

    var rule = 'every $pattern';
    final ac = tail(k, 'afterCompletion');
    if (ac != 0 && parseRule('$rule after completion').ok) {
      rule += ' after completion';
      k += ac;
    }
    startTail();
    final until = tail(k, 'untilWords');
    if (until != 0) {
      final dm = matchDateAt(tokens, k + until, ctx);
      if (dm != null && parseRule('$rule until ${dm.date}').ok) {
        rule += ' until ${dm.date}';
        k = dm.to;
      }
    } else {
      for (final w in ctx.vocabs) {
        final pre = phraseAt(tokens, k, w.timesWords.before, '${w.code}:tb4');
        final count = countAt(tokens, k + pre, w);
        final countTok = _tok(tokens, k + pre);
        if (count == null || countTok == null || !RegExp(r'^\d+$').hasMatch(countTok.norm)) continue;
        final post = phraseAt(tokens, k + pre + count.n, w.timesWords.after, '${w.code}:taft');
        if (post != 0 && parseRule('$rule for ${count.count} times').ok) {
          rule += ' for ${count.count} times';
          k += pre + count.n + post;
          break;
        }
      }
    }
    startTail();
    final parsed = parseRule(rule);
    if (!parsed.ok) return;
    if (best == null || k > best!.to) {
      best = RecurrenceMatch(rule: parsed.canonical!, from: i, to: k, start: start);
    }
  }

  for (final v in ctx.vocabs) {
    // "every other" first: on a tie it wins over the ordinal reading of "jeden zweiten Freitag".
    final other = _everyOtherAt(tokens, i, v);
    if (other != null) consider(other.pattern, i + other.n);
    final one = lookupAt(tokens, i, v.everyOne, '${v.code}:every1');
    if (one != null) {
      consider(one.value, i + one.n);
      continue;
    }
    final ev = phraseAt(tokens, i, v.every, '${v.code}:every');
    if (ev == 0) continue;
    final p = _patternAt(tokens, i + ev, v);
    if (p == null) {
      final literal = _countWeekdayAt(tokens, i + ev, v);
      if (literal != 0 && (best == null || i + ev + literal > best!.to)) {
        best = RecurrenceMatch(rule: '', from: i, to: i + ev + literal, literal: true);
      }
      continue;
    }
    consider(p.pattern, i + ev + p.n + (p.monthly ? ofMonthAt(tokens, i + ev + p.n, ctx) : 0));
  }
  return best;
}
