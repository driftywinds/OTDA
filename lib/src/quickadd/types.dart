// The values the parser returns, mirroring the slice of web/src/lib/types.ts it uses.

/// A floating due date: `{"date": "YYYY-MM-DD", "time": "HH:MM"?}`.
/// Dates are floating strings; there is never a time zone or a `Date` here.
class Due {
  const Due(this.date, [this.time]);

  final String date;
  final String? time;

  Map<String, Object?> toJson() => {'date': date, if (time != null) 'time': time};

  @override
  bool operator ==(Object other) => other is Due && other.date == date && other.time == time;

  @override
  int get hashCode => Object.hash(date, time);

  @override
  String toString() => time == null ? 'Due($date)' : 'Due($date $time)';
}
