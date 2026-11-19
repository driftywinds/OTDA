/// Reads a number the server may send in any of the shapes JSON allows: a number,
/// a numeric string (int64) or an ISO date. A cast used to throw inside a build
/// method, which blanked the whole screen.
num? numOrNull(Object? value) {
  if (value is num) return value;
  if (value is DateTime) return value.millisecondsSinceEpoch;
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  final direct = num.tryParse(text);
  if (direct != null) return direct;
  return DateTime.tryParse(text)?.millisecondsSinceEpoch;
}
