import 'package:intl/intl.dart';

/// Whole days from [today] to [date], both `YYYY-MM-DD`; negative when [date]
/// is in the past. Null when either does not parse.
int? daysBetween(String today, String date) {
  final a = DateTime.tryParse(today);
  final b = DateTime.tryParse(date);
  if (a == null || b == null) return null;
  return DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

/// A date the way a person says it: Today, Tomorrow, Yesterday, a weekday for
/// the coming week, otherwise "Nov 23" (with the year when it is not this one).
String friendlyDate(String date, String today) {
  final days = daysBetween(today, date);
  final parsed = DateTime.tryParse(date);
  if (days == null || parsed == null) return date;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days == -1) return 'Yesterday';
  if (days > 1 && days < 7) return DateFormat.E().format(parsed);
  final sameYear = parsed.year == DateTime.parse(today).year;
  return (sameYear ? DateFormat.MMMd() : DateFormat.yMMMd()).format(parsed);
}

/// Minutes as "45m", "2h" or "1h 30m".
String durationLabel(int minutes) {
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

/// "Wednesday, 18 November" for the header under a view's title.
String longToday(DateTime now) => DateFormat('EEEE, d MMMM').format(now);
