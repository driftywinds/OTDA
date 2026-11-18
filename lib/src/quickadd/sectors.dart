// Time sectors: the slice of web/src/lib/sectors.ts the parser needs (a relative
// phrase → the stored ISO week, month or quarter). Ported from OpenTodo v1.5.0.
//
// The stored value is absolute, an ISO week `2026-W44`, a month `2026-11` or a
// quarter `2026-Q4`; everything relative is derived from the viewer's local date
// and first day of the week, and never written.

const List<String> sectorWords = [
  'this-week',
  'next-week',
  'this-month',
  'next-month',
  'this-quarter',
  'next-quarter',
];

class Period {
  const Period({required this.kind, required this.year, required this.n});

  /// week, month or quarter.
  final String kind;
  final int year;

  /// The week (1–53), month (1–12) or quarter (1–4).
  final int n;
}

final RegExp _sectorRe = RegExp(r'^(\d{4})-(?:W(\d{2})|(\d{2})|Q(\d))$');
const int _day = 86400000;

int _toMs(String iso) => DateTime.utc(
      int.parse(iso.substring(0, 4)),
      int.parse(iso.substring(5, 7)),
      int.parse(iso.substring(8, 10)),
    ).millisecondsSinceEpoch;

String _toIso(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${_pad4(d.year)}-${_pad2(d.month)}-${_pad2(d.day)}';
}

String _addDays(String iso, int days) => _toIso(_toMs(iso) + days * _day);

String _pad2(int n) => n.toString().padLeft(2, '0');

String _pad4(int n) => n.toString().padLeft(4, '0');

/// ISO weekday: 1 Monday … 7 Sunday (Dart's [DateTime.weekday] already is).
int isoDow(String iso) => DateTime.fromMillisecondsSinceEpoch(_toMs(iso), isUtc: true).weekday;

/// The ISO week a date falls in.
({int year, int week}) isoWeekOf(String iso) {
  final thursday = _addDays(iso, 4 - isoDow(iso));
  final year = int.parse(thursday.substring(0, 4));
  final week = ((_toMs(thursday) - _toMs('$year-01-01')) ~/ _day ~/ 7) + 1;
  return (year: year, week: week);
}

/// 52 or 53: the number of ISO weeks of a year (28 December is always in the last).
int isoWeeksIn(int year) => isoWeekOf('$year-12-28').week;

/// The Monday of an ISO week.
String mondayOfWeek(int year, int week) {
  final jan4 = '$year-01-04';
  return _addDays(jan4, 1 - isoDow(jan4) + (week - 1) * 7);
}

/// A stored sector as a period, or null when empty or invalid (years 2000–2999).
Period? parseSector(Object? value) {
  if (value is! String) return null;
  final m = _sectorRe.firstMatch(value);
  if (m == null) return null;
  final year = int.parse(m[1]!);
  if (year < 2000 || year > 2999) return null;
  if (m[2] != null) {
    final n = int.parse(m[2]!);
    return n >= 1 && n <= isoWeeksIn(year) ? Period(kind: 'week', year: year, n: n) : null;
  }
  if (m[3] != null) {
    final n = int.parse(m[3]!);
    return n >= 1 && n <= 12 ? Period(kind: 'month', year: year, n: n) : null;
  }
  final n = int.parse(m[4]!);
  return n >= 1 && n <= 4 ? Period(kind: 'quarter', year: year, n: n) : null;
}

String formatPeriod(Period p) {
  if (p.kind == 'week') return '${p.year}-W${_pad2(p.n)}';
  if (p.kind == 'month') return '${p.year}-${_pad2(p.n)}';
  return '${p.year}-Q${p.n}';
}

/// The period after `p`, of the same kind.
Period nextOf(Period p) {
  final max = p.kind == 'week' ? isoWeeksIn(p.year) : (p.kind == 'month' ? 12 : 4);
  return p.n < max ? Period(kind: p.kind, year: p.year, n: p.n + 1) : Period(kind: p.kind, year: p.year + 1, n: 1);
}

/// The viewer's current periods (design D3). This week is the ISO week holding the
/// Monday that falls inside the viewer's current week. `weekStart` is 0 (Sunday)
/// to 6 (Saturday).
Map<String, String> currentPeriods(String localDate, [int weekStart = 1]) {
  final ws = ((weekStart % 7) + 7) % 7;
  final dow = isoDow(localDate) % 7; // 0 Sunday … 6 Saturday
  final start = _addDays(localDate, -((dow - ws + 7) % 7));
  final monday = _addDays(start, (1 - ws + 7) % 7);
  final w = isoWeekOf(monday);
  final week = Period(kind: 'week', year: w.year, n: w.week);
  final year = int.parse(localDate.substring(0, 4));
  final monthN = int.parse(localDate.substring(5, 7));
  final month = Period(kind: 'month', year: year, n: monthN);
  final quarter = Period(kind: 'quarter', year: year, n: ((monthN - 1) ~/ 3) + 1);
  return {
    'this-week': formatPeriod(week),
    'next-week': formatPeriod(nextOf(week)),
    'this-month': formatPeriod(month),
    'next-month': formatPeriod(nextOf(month)),
    'this-quarter': formatPeriod(quarter),
    'next-quarter': formatPeriod(nextOf(quarter)),
  };
}

/// The sector a relative word means on the viewer's date, or null for an unknown word.
String? resolvePhrase(String word, String localDate, [int weekStart = 1]) {
  final w = word.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
  return sectorWords.contains(w) ? currentPeriods(localDate, weekStart)[w] : null;
}
