// Reminder phrases in the quick-add line (quick-add-recurrence D1, D3): a reminder
// word ("remind me", "erinnere mich", "rappelle-moi") followed by an offset
// ("30 min before", "1 hour after") or a moment (a time phrase, optionally with a
// date phrase: "at 9", "tomorrow at 9", "20 Oct at 9").
// Ported from web/src/lib/nlp/reminders.ts (OpenTodo v1.5.0).
import 'attributes.dart' show matchDuration;
import 'dates.dart';
import 'tokenize.dart';
import 'vocab/index.dart';

/// A reminder as typed: an offset from the due (negative = before) or a floating
/// wall-clock moment.
class ReminderPhrase {
  const ReminderPhrase.offset(int this.minutes)
      : kind = 'offset',
        date = null,
        time = null;

  const ReminderPhrase.moment({this.date, required String this.time})
      : kind = 'moment',
        minutes = null;

  /// 'offset' or 'moment'.
  final String kind;

  /// The offset in minutes (negative = before), for an offset reminder.
  final int? minutes;

  /// The date of a moment reminder, or null for the due date.
  final String? date;

  /// The time of a moment reminder, HH:MM.
  final String? time;

  Map<String, Object?> toJson() => kind == 'offset'
      ? {'kind': kind, 'minutes': minutes}
      : {'kind': kind, 'date': date, 'time': time};

  @override
  bool operator ==(Object other) =>
      other is ReminderPhrase && other.kind == kind && other.minutes == minutes && other.date == date && other.time == time;

  @override
  int get hashCode => Object.hash(kind, minutes, date, time);

  @override
  String toString() => kind == 'offset' ? 'ReminderPhrase.offset($minutes)' : 'ReminderPhrase.moment($date, $time)';
}

class ReminderMatch {
  const ReminderMatch({required this.reminder, required this.from, required this.to});

  final ReminderPhrase reminder;
  final int from;
  final int to;
}

const Map<String, int> _unitMinutes = {'minute': 1, 'hour': 60, 'day': 1440, 'week': 10080};

({int n, int minutes})? _offsetUnitAt(List<Token> tokens, int i, Vocabulary v) {
  for (final unit in ['minute', 'hour', 'day', 'week']) {
    final n = phraseAt(tokens, i, v.units[unit], '${v.code}:unit:$unit');
    if (n != 0) return (n: n, minutes: _unitMinutes[unit]!);
  }
  return null;
}

/// An offset at token k: a count and a unit, or a compact duration ("30min", "2h"),
/// then a before or after word.
({int n, int minutes})? _offsetAt(List<Token> tokens, int k, DateContext ctx) {
  ({int n, int minutes})? best;
  for (final v in ctx.vocabs) {
    ({int n, int minutes})? amount;
    final count = countAt(tokens, k, v);
    if (count != null) {
      final unit = _offsetUnitAt(tokens, k + count.n, v);
      if (unit != null) amount = (n: count.n + unit.n, minutes: count.count * unit.minutes);
    }
    final t = k >= 0 && k < tokens.length ? tokens[k] : null;
    if (amount == null && t != null && !t.quoted) {
      final m = matchDuration(t.text, bareHourIsTime: false);
      if (m != null) amount = (n: 1, minutes: m);
    }
    if (amount == null || amount.minutes <= 0) continue;
    final before = phraseAt(tokens, k + amount.n, v.beforeWords, '${v.code}:rbefore');
    final after = before != 0 ? 0 : phraseAt(tokens, k + amount.n, v.afterWords, '${v.code}:rafter');
    if (before == 0 && after == 0) continue;
    final n = amount.n + (before != 0 ? before : after);
    if (best == null || n > best.n) best = (n: n, minutes: before != 0 ? -amount.minutes : amount.minutes);
  }
  return best;
}

/// A moment at token k: [date] time or time [date].
({int n, String? date, String time})? _momentAt(List<Token> tokens, int k, DateContext ctx) {
  final dateFirst = matchDateAt(tokens, k, ctx);
  if (dateFirst != null) {
    final item = matchTimeAt(tokens, dateFirst.to, ctx);
    if (item != null) return (n: item.to - k, date: dateFirst.date, time: item.time);
  }
  final entry = matchTimeAt(tokens, k, ctx);
  if (entry == null) return null;
  final d = matchDateAt(tokens, entry.to, ctx);
  if (d != null) return (n: d.to - k, date: d.date, time: entry.time);
  return (n: entry.to - k, date: entry.date, time: entry.time);
}

/// The longest reminder phrase at token i; a reminder word alone does not match.
ReminderMatch? matchReminderAt(List<Token> tokens, int i, DateContext ctx) {
  final t = i >= 0 && i < tokens.length ? tokens[i] : null;
  if (t == null || t.quoted) return null;
  var word = 0;
  for (final v in ctx.vocabs) {
    final n = phraseAt(tokens, i, v.remindWords, '${v.code}:remind');
    if (n > word) word = n;
  }
  if (word == 0) return null;
  final r = parseReminderAt(tokens, i + word, ctx);
  return r == null ? null : ReminderMatch(reminder: r.reminder, from: i, to: r.to);
}

/// The reminder body (offset or moment) at token k, without the reminder word.
({ReminderPhrase reminder, int to})? parseReminderAt(List<Token> tokens, int k, DateContext ctx) {
  final off = _offsetAt(tokens, k, ctx);
  final mom = _momentAt(tokens, k, ctx);
  if (off != null && (mom == null || off.n >= mom.n)) {
    return (reminder: ReminderPhrase.offset(off.minutes), to: k + off.n);
  }
  if (mom != null) return (reminder: ReminderPhrase.moment(date: mom.date, time: mom.time), to: k + mom.n);
  return null;
}

/// How a typed reminder is stored once the due date is known (design D3).
class ResolvedReminder {
  const ResolvedReminder.relative(int this.offsetMinutes)
      : kind = 'relative',
        date = null,
        time = null;

  const ResolvedReminder.absolute({required String this.date, required String this.time})
      : kind = 'absolute',
        offsetMinutes = null;

  /// 'relative' or 'absolute'.
  final String kind;
  final int? offsetMinutes;
  final String? date;
  final String? time;
}

int _dayNumberOf(String iso) {
  final p = iso.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]).millisecondsSinceEpoch ~/ 86400000;
}

int _minutesOf(String hhmm) {
  final p = hhmm.split(':').map(int.parse).toList();
  return p[0] * 60 + p[1];
}

/// Resolve a typed reminder against the task's final due: an offset is relative; a
/// moment is relative to the due time (09:00 for a date-only due) on wall-clock
/// days and minutes; without a due a moment is absolute, its date today, or
/// tomorrow when the time has passed.
ResolvedReminder resolveReminder(ReminderPhrase r, Map<String, Object?>? due, String today, String now) {
  if (r.kind == 'offset') return ResolvedReminder.relative(r.minutes!);
  if (due != null) {
    final dueAt = _dayNumberOf(due['date'] as String) * 1440 + _minutesOf((due['time'] as String?) ?? '09:00');
    final at = _dayNumberOf(r.date ?? due['date'] as String) * 1440 + _minutesOf(r.time!);
    return ResolvedReminder.relative(at - dueAt);
  }
  if (r.date != null) return ResolvedReminder.absolute(date: r.date!, time: r.time!);
  if (_minutesOf(r.time!) > _minutesOf(now)) return ResolvedReminder.absolute(date: today, time: r.time!);
  final p = today.split('-').map(int.parse).toList();
  final next = DateTime.utc(p[0], p[1], p[2] + 1);
  return ResolvedReminder.absolute(
    date: '${next.year.toString().padLeft(4, '0')}-${next.month.toString().padLeft(2, '0')}-${next.day.toString().padLeft(2, '0')}',
    time: r.time!,
  );
}

/// "30 min before", "1 hour after", "2 days before", "at due time" for an offset
/// in minutes. English only: the web app translates this through its catalogue.
String describeOffset(int minutes) {
  if (minutes == 0) return 'at due time';
  final a = minutes.abs();
  final before = minutes < 0;
  if (a % 1440 == 0) {
    final n = a ~/ 1440;
    if (before) return '$n ${n == 1 ? 'day' : 'days'} before';
    return '$n ${n == 1 ? 'day' : 'days'} after';
  }
  if (a % 60 == 0) {
    final n = a ~/ 60;
    if (before) return '$n ${n == 1 ? 'hour' : 'hours'} before';
    return '$n ${n == 1 ? 'hour' : 'hours'} after';
  }
  return before ? '$a min before' : '$a min after';
}
