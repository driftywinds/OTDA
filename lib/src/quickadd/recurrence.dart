// The recurring-tasks rule grammar, canonical form and first occurrence, ported
// from web/src/lib/recurrence.ts (OpenTodo v1.5.0). Only what the quick-add
// parser needs is here: parseRule, canonicalOf, nthWeekdayDate, firstOccurrence
// and compatibleRule.
//
// Dates are floating YYYY-MM-DD strings. All arithmetic runs on proleptic
// Gregorian day numbers, never on `DateTime`, so results do not depend on the
// device's time zone or on daylight saving changes.

const int maxRuleLength = 200;
const int _maxInterval = 999;
const int _maxCount = 10000;

class Rule {
  Rule({
    required this.kind,
    this.interval = 1,
    this.unit = 'day',
    this.afterCompletion = false,
    this.days = 0,
    this.monthDay = 0,
    this.ordinal = 0,
    this.weekday = 0,
    this.month = 0,
    this.until,
    this.count = 0,
  });

  /// interval, weekday, weekdays, monthDay, lastDay, workday or nthWeekday.
  String kind;

  /// `every N <unit>`.
  int interval;
  String unit;

  /// `after completion` (interval rules only).
  bool afterCompletion;

  /// The weekday mask of `weekday` / `weekdays`.
  int days;

  /// `every 15th`.
  int monthDay;

  /// The ordinal of `workday` / `nthWeekday`: 1–4, or -1 for the last.
  int ordinal;

  /// 1 = Monday … 7 = Sunday (`nthWeekday`).
  int weekday;

  /// 1–12 for a yearly `nthWeekday`, 0 otherwise.
  int month;

  /// YYYY-MM-DD or null.
  String? until;

  /// `for N times`, 0 when absent.
  int count;

  Rule copy() => Rule(
        kind: kind,
        interval: interval,
        unit: unit,
        afterCompletion: afterCompletion,
        days: days,
        monthDay: monthDay,
        ordinal: ordinal,
        weekday: weekday,
        month: month,
        ,
      );
}

class RuleParse {
  const RuleParse.ok(this.rule, this.canonical)
      : ok = true,
        error = null;
  const RuleParse.fail(this.error)
      : ok = false,
        rule = null,
        canonical = null;

  final bool ok;
  final Rule? rule;

  /// The form to store; null when the input does not parse.
  final String? canonical;

  /// Why it did not parse (English only: the web app translates these, the parser
  /// never shows them).
  final String? error;
}

const List<String> _weekdayNames = ['', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
const Map<String, int> _weekdayAliases = {
  'monday': 1, 'mon': 1,
  'tuesday': 2, 'tue': 2,
  'wednesday': 3, 'wed': 3,
  'thursday': 4, 'thu': 4,
  'friday': 5, 'fri': 5,
  'saturday': 6, 'sat': 6,
  'sunday': 7, 'sun': 7,
};
const Map<String, int> _wordOrdinals = {'first': 1, 'second': 2, 'third': 3, 'fourth': 4, 'last': -1};
const List<String> _monthNames = [
  '', 'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december',
];
const List<String> _units = ['day', 'week', 'month', 'year'];

String ordinalSuffix(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return 'th';
  return n % 10 == 1 ? 'st' : (n % 10 == 2 ? 'nd' : (n % 10 == 3 ? 'rd' : 'th'));
}

int? _numericOrdinal(String tok) {
  final m = RegExp(r'^([1-9][0-9]?)(st|nd|rd|th)$').firstMatch(tok);
  if (m == null) return null;
  final n = int.parse(m[1]!);
  return n <= 31 && m[2] == ordinalSuffix(n) ? n : null;
}

int? _positiveInt(String? tok, int max) {
  if (tok == null || !RegExp(r'^[1-9][0-9]*$').hasMatch(tok)) return null;
  final n = int.parse(tok);
  return n <= max ? n : null;
}

class _RuleError implements Exception {
  const _RuleError(this.message);

  final String message;
}

/// Parse a rule; on success `canonical` is the form to store.
RuleParse parseRule(String input) {
  try {
    final rule = _parseOrThrow(input);
    return RuleParse.ok(rule, canonicalOf(rule));
  } on _RuleError catch (e) {
    return RuleParse.fail(e.message);
  }
}

/// The canonical form of a valid rule, or null when it does not parse.
String? canonicalRule(String input) {
  final r = parseRule(input);
  return r.ok ? r.canonical : null;
}

Rule _parseOrThrow(String input) {
  if (input.length > maxRuleLength) throw const _RuleError('longer than 200 characters');
  final toks = input.toLowerCase().replaceAll(',', ' , ').split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (toks.isEmpty || toks[0] != 'every') throw const _RuleError('must start with "every"');
  var i = 1;
  String? peek([int k = 0]) => i + k < toks.length ? toks[i + k] : null;

  // `name ((, | and | , and) name)*` from token i: the weekday mask.
  int weekdayList() {
    var days = 0;
    while (true) {
      final item = peek();
      if (item == null || !_weekdayAliases.containsKey(item)) throw _RuleError('expected a weekday, got "$item"');
      days |= 1 << _weekdayAliases[item]!;
      i++;
      var j = i;
      if ((j < toks.length ? toks[j] : null) == ',') j++;
      if ((j < toks.length ? toks[j] : null) == 'and') j++;
      if (j == i) return days;
      if (j >= toks.length) throw const _RuleError('expected a weekday after the list separator');
      i = j;
    }
  }

  final tok = peek();
  if (tok == null) throw const _RuleError('missing pattern after "every"');
  Rule rule;
  if (tok == 'day' || tok == 'week' || tok == 'month' || tok == 'year') {
    rule = Rule(kind: 'interval', interval: 1, unit: tok);
    i++;
    if (tok == 'week' && peek() == 'on') {
      i++;
      rule = Rule(kind: 'weekdays', days: weekdayList(), interval: 1);
    }
  } else if (tok == 'weekday' || tok == 'weekdays') {
    rule = Rule(kind: 'weekday', days: 0x3E);
    i++;
  } else if (RegExp(r'^[0-9]+$').hasMatch(tok)) {
    final n = _positiveInt(tok, _maxInterval);
    if (n == null) throw const _RuleError('interval must be from 1 to 999');
    final singular = (peek(1) ?? '').replaceFirst(RegExp(r's$'), '');
    if (!_units.contains(singular)) throw _RuleError('expected day(s), week(s), month(s) or year(s) after $tok');
    rule = Rule(kind: 'interval', interval: n, unit: singular);
    i += 2;
    // every N weeks on <weekdays> (quick-add-weekday-recurrence D1).
    if (singular == 'week' && peek() == 'on') {
      i++;
      rule = Rule(kind: 'weekdays', days: weekdayList(), interval: n);
    }
  } else if (tok == 'last' && (peek(1) == 'day' || peek(1) == 'weekday')) {
    rule = peek(1) == 'day'
        ? Rule(kind: 'lastDay')
        : Rule(kind: 'workday', ordinal: -1);
    i += 2;
  } else if (_weekdayAliases.containsKey(tok)) {
    rule = Rule(kind: 'weekdays', days: weekdayList(), interval: 1);
  } else {
    final word = _wordOrdinals[tok];
    final num = _numericOrdinal(tok);
    if (word == null && num == null) throw _RuleError('unknown pattern "$tok"');
    final next = peek(1);
    if (next == 'weekday') {
      final ordinal = num ?? word ?? 0;
      if (ordinal > 4) throw const _RuleError('weekday ordinal must be 1st to 4th or last');
      rule = Rule(kind: 'workday', ordinal: ordinal);
      i += 2;
    } else if (next != null && _weekdayAliases.containsKey(next)) {
      // One of the two is set (checked above).
      final ordinal = num ?? word ?? 0;
      if (ordinal > 4) throw const _RuleError('weekday ordinal must be 1st to 4th or last');
      rule = Rule(kind: 'nthWeekday', ordinal: ordinal, weekday: _weekdayAliases[next]!);
      i += 2;
      // `of <month>` (or `in <month>`) makes it yearly (yearly-weekday-of-month D1).
      final monthWord = peek(1) ?? '';
      if ((peek() == 'of' || peek() == 'in') && _monthAliases.containsKey(monthWord)) {
        rule.month = _monthAliases[monthWord]!;
        i += 2;
      }
    } else {
      if (num == null) throw _RuleError('expected a weekday after "$tok"');
      rule = Rule(kind: 'monthDay', monthDay: num);
      i++;
    }
  }
  if (peek() == 'after') {
    if (peek(1) != 'completion') throw const _RuleError('expected "completion" after "after"');
    if (rule.kind != 'interval') throw const _RuleError('"after completion" only applies to day, week, month and year intervals');
    rule.afterCompletion = true;
    i += 2;
  }
  if (peek() == 'until') {
    final d = peek(1);
    if (d == null || _dayNumberIso(d) == null) throw const _RuleError('until needs a date YYYY-MM-DD');
    rule.until = d;
    i += 2;
  } else if (peek() == 'for') {
    final n = _positiveInt(peek(1), _maxCount);
    if (n == null || (peek(2) != 'times' && peek(2) != 'time')) throw const _RuleError('expected "for N times" with N from 1 to 10000');
    rule.count = n;
    i += 3;
  }
  if (i < toks.length) throw _RuleError('unexpected "${toks[i]}"');
  return rule;
}

final Map<String, int> _monthAliases = () {
  final map = <String, int>{'sept': 9};
  for (var m = 1; m < _monthNames.length; m++) {
    final name = _monthNames[m];
    map[name] = m;
    map[name.substring(0, 3)] = m;
  }
  return map;
}();

/// The canonical text of a parsed rule.
String canonicalOf(Rule r) {
  var s = 'every ';
  switch (r.kind) {
    case 'interval':
      s += r.interval == 1 ? r.unit : '${r.interval} ${r.unit}s';
    case 'weekday':
      s += 'weekday';
    case 'weekdays':
      if (r.interval > 1) s += '${r.interval} weeks on ';
      s += _weekdayNames.asMap().entries.where((e) => e.key > 0 && r.days & (1 << e.key) != 0).map((e) => e.value).join(', ');
    case 'monthDay':
      s += '${r.monthDay}${ordinalSuffix(r.monthDay)}';
    case 'lastDay':
      s += 'last day';
    case 'workday':
      s += '${r.ordinal < 0 ? 'last' : '${r.ordinal}${ordinalSuffix(r.ordinal)}'} weekday';
    case 'nthWeekday':
      s += '${r.ordinal < 0 ? 'last' : '${r.ordinal}${ordinalSuffix(r.ordinal)}'} ${_weekdayNames[r.weekday]}';
      if (r.month != 0) s += ' of ${_monthNames[r.month]}';
  }
  if (r.afterCompletion) s += ' after completion';
  if (r.until != null) s += ' until ${r.until}';
  if (r.count == 1) {
    s += ' for 1 time';
  } else if (r.count > 1) {
    s += ' for ${r.count} times';
  }
  return s;
}

// ---- calendar arithmetic on day numbers (days since 1970-01-01) ----

/// Integer division that rounds toward negative infinity (like Math.floor).
int _floorDiv(int a, int b) => (a - a % b) ~/ b;

int _daysFromCivil(int y, int m, int d) {
  y -= m <= 2 ? 1 : 0;
  final era = _floorDiv(y, 400);
  final yoe = y - era * 400;
  final doy = _floorDiv(153 * (m > 2 ? m - 3 : m + 9) + 2, 5) + d - 1;
  final doe = yoe * 365 + _floorDiv(yoe, 4) - _floorDiv(yoe, 100) + doy;
  return era * 146097 + doe - 719468;
}

List<int> _civilFromDays(int z) {
  z += 719468;
  final era = _floorDiv(z, 146097);
  final doe = z - era * 146097;
  final yoe = _floorDiv(doe - _floorDiv(doe, 1460) + _floorDiv(doe, 36524) - _floorDiv(doe, 146096), 365);
  final doy = doe - (365 * yoe + _floorDiv(yoe, 4) - _floorDiv(yoe, 100));
  final mp = _floorDiv(5 * doy + 2, 153);
  final d = doy - _floorDiv(153 * mp + 2, 5) + 1;
  final m = mp < 10 ? mp + 3 : mp - 9;
  return [yoe + era * 400 + (m <= 2 ? 1 : 0), m, d];
}

bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);

int _monthLen(int y, int m) {
  if (m == 2) return _isLeap(y) ? 29 : 28;
  return m == 4 || m == 6 || m == 9 || m == 11 ? 30 : 31;
}

/// ISO weekday, 1 = Monday … 7 = Sunday; day 0 (1970-01-01) was a Thursday.
int _isoWeekday(int z) => ((z + 3) % 7) + 1;

/// Day number of a valid YYYY-MM-DD date, or null.
int? _dayNumberIso(String s) {
  final m = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$').firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > _monthLen(y, mo)) return null;
  return _daysFromCivil(y, mo, d);
}

String _formatDate(int z) {
  final p = _civilFromDays(z);
  return '${p[0].toString().padLeft(4, '0')}-${p[1].toString().padLeft(2, '0')}-${p[2].toString().padLeft(2, '0')}';
}

int _mustDate(String s, String what) {
  final z = _dayNumberIso(s);
  if (z == null) throw ArgumentError('recurrence: $what "$s" is not a valid YYYY-MM-DD date');
  return z;
}

int _addMonths(int z, int n) {
  final p = _civilFromDays(z);
  final idx = p[0] * 12 + (p[1] - 1) + n;
  final ny = _floorDiv(idx, 12);
  final nm = idx - ny * 12 + 1;
  final d = p[2];
  final len = _monthLen(ny, nm);
  return _daysFromCivil(ny, nm, d < len ? d : len);
}

int _step(Rule r, int anchor, int k) {
  switch (r.unit) {
    case 'week':
      return anchor + 7 * r.interval * k;
    case 'month':
      return _addMonths(anchor, r.interval * k);
    case 'year':
      return _addMonths(anchor, 12 * r.interval * k);
    default:
      return anchor + r.interval * k;
  }
}

/// The `ordinal`-th Monday-to-Friday day of month m (1–4, or -1 for the last);
/// weekends are not counted.
int _workdayOf(int y, int m, int ordinal) {
  if (ordinal < 0) {
    var z = _daysFromCivil(y, m, _monthLen(y, m));
    while (_isoWeekday(z) > 5) {
      z--;
    }
    return z;
  }
  var z = _daysFromCivil(y, m, 1) - 1;
  for (var n = 0; n < ordinal;) {
    z++;
    if (_isoWeekday(z) <= 5) n++;
  }
  return z;
}

int _nthWeekdayOf(int y, int m, int ordinal, int wd) {
  if (ordinal < 0) {
    final z = _daysFromCivil(y, m, _monthLen(y, m));
    return z - ((_isoWeekday(z) - wd + 7) % 7);
  }
  final first = _daysFromCivil(y, m, 1);
  return first + ((wd - _isoWeekday(first) + 7) % 7) + 7 * (ordinal - 1);
}

/// The date of the `ordinal`-th `weekday` (1 = Monday … 7 = Sunday) of month `m`
/// of year `y`, as YYYY-MM-DD; `ordinal` is 1–4, or -1 for the last. Quick add
/// resolves one-off ordinal weekdays with it ("second Monday").
String nthWeekdayDate(int y, int m, int ordinal, int weekday) =>
    _formatDate(_nthWeekdayOf(y, m, ordinal, weekday));

int _inMonth(Rule r, int y, int m) {
  switch (r.kind) {
    case 'monthDay':
      final len = _monthLen(y, m);
      return _daysFromCivil(y, m, r.monthDay < len ? r.monthDay : len);
    case 'lastDay':
      return _daysFromCivil(y, m, _monthLen(y, m));
    case 'workday':
      return _workdayOf(y, m, r.ordinal);
    case 'nthWeekday':
      return _nthWeekdayOf(y, m, r.ordinal, r.weekday);
    default:
      throw ArgumentError('recurrence: not a month pattern');
  }
}

/// The Monday of z's ISO week.
int _weekStart(int z) => z - (_isoWeekday(z) - 1);

/// For `every N weeks on <days>`: the first of its days strictly after z in a week
/// a multiple of N weeks from anchor's ISO week (Monday to Sunday).
int _inPhaseAfter(Rule r, int anchor, int z) {
  final a = _weekStart(anchor);
  var x = z + 1;
  while (true) {
    final rem = ((_floorDiv(_weekStart(x) - a, 7) % r.interval) + r.interval) % r.interval;
    if (rem != 0) {
      x = _weekStart(x) + 7 * (r.interval - rem);
      continue;
    }
    if (r.days & (1 << _isoWeekday(x)) != 0) return x;
    x++;
  }
}

/// First date matching the pattern strictly after day z.
int _firstAfter(Rule r, int z) {
  switch (r.kind) {
    case 'interval':
      return _step(r, z, 1);
    case 'weekday':
    case 'weekdays':
      if (r.kind == 'weekdays' && r.interval > 1) return _inPhaseAfter(r, z, z);
      for (var i = 1; i <= 7; i++) {
        if (r.days & (1 << _isoWeekday(z + i)) != 0) return z + i;
      }
      return z + 7;
    default:
      final p = _civilFromDays(z);
      final y = p[0], m = p[1];
      if (r.kind == 'nthWeekday' && r.month != 0) {
        final c = _nthWeekdayOf(y, r.month, r.ordinal, r.weekday);
        return c > z ? c : _nthWeekdayOf(y + 1, r.month, r.ordinal, r.weekday);
      }
      final c = _inMonth(r, y, m);
      if (c > z) return c;
      return m == 12 ? _inMonth(r, y + 1, 1) : _inMonth(r, y, m + 1);
  }
}

Rule _asRule(String rule) {
  final p = parseRule(rule);
  if (!p.ok) throw ArgumentError('recurrence: ${p.error}');
  return p.rule!;
}

/// First occurrence on or after `from`: the due date given to an undated task
/// that gets a rule.
String firstOccurrence(String rule, String from) {
  final r = _asRule(rule);
  final z = _mustDate(from, 'from');
  if (r.kind == 'interval') return from;
  // `every 2 weeks on saturday`: the nearest Saturday, which then sets the week phase.
  final probe = r.kind == 'weekdays' ? (r.copy()..interval = 1) : r;
  return _formatDate(_firstAfter(probe, z - 1));
}

/// The rule a writer stores for a task due on `due`: `every N weeks on <day>`
/// whose due date falls on that day is stored as `every N weeks`, which the due
/// date anchors (recurrence-1-0-compatible). A rule that does not parse is
/// returned as given.
String compatibleRule(String rule, String? due) {
  final p = parseRule(rule);
  if (!p.ok) return rule;
  final r = p.rule!;
  final z = due == null ? null : _dayNumberIso(due);
  if (r.kind != 'weekdays' || r.interval <= 1 || z == null || r.days != 1 << _isoWeekday(z)) return p.canonical!;
  return canonicalOf(Rule(
    kind: 'interval',
    interval: r.interval,
    unit: 'week',
    until: r.until,
    count: r.count,
  ));
}
