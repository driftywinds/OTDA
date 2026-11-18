// Per-language vocabulary for the quick-add date and time grammar.
//
// Ported from web/src/lib/nlp/vocab/types.ts (OpenTodo v1.5.0). Every entry is
// matched against tokens after `normalize()` (lower case, diacritics stripped,
// "ß" → "ss"), so vocabularies may be written with their natural spelling.
// Multi-word phrases are written with single spaces and matched across tokens.
// Abbreviations that end in "." only match tokens that also end in "." (German
// "Mi."), which keeps two-letter abbreviations from swallowing ordinary words.

/// Default interpretation of an ambiguous numeric date such as 12/11.
enum DayMonthOrder {
  dm('DM'),
  md('MD');

  const DayMonthOrder(this.code);

  /// The TS spelling: 'DM' or 'MD'.
  final String code;
}

class MonthVocab {
  const MonthVocab({required this.names, required this.abbr});

  /// Full names; alone (without a day) they resolve to the first of the month.
  final List<String> names;

  /// Abbreviations; only recognised next to a day number (design D4).
  final List<String> abbr;
}

/// The unit words: minute and year only in reminder and recurrence phrases.
class Units {
  const Units({
    required this.minute,
    required this.hour,
    required this.day,
    required this.week,
    required this.month,
    required this.year,
  });

  final List<String> minute;
  final List<String> hour;
  final List<String> day;
  final List<String> week;
  final List<String> month;
  final List<String> year;

  List<String> operator [](String unit) => switch (unit) {
        'minute' => minute,
        'hour' => hour,
        'day' => day,
        'week' => week,
        'month' => month,
        'year' => year,
        _ => const [],
      };
}

/// "for N times": words before and after the count.
class TimesWords {
  const TimesWords({required this.before, required this.after});

  final List<String> before;
  final List<String> after;
}

/// "every other" around the unit or weekday: French "un vendredi sur deux".
class Around {
  const Around({required this.before, required this.after});

  final List<String> before;
  final List<String> after;
}

class Vocabulary {
  const Vocabulary({
    required this.code,
    required this.dayMonthOrder,
    required this.dayWords,
    required this.weekdays,
    required this.months,
    required this.before,
    required this.deadlineWords,
    required this.byWords,
    required this.somedayWords,
    required this.sectorPhrases,
    required this.eveningWords,
    required this.morningWords,
    required this.afternoonWords,
    required this.partWords,
    required this.nextBefore,
    required this.nextAfter,
    required this.thisBefore,
    required this.inWords,
    required this.oneWords,
    required this.units,
    required this.ofWords,
    required this.atWords,
    required this.hourWords,
    required this.hourSuffixH,
    required this.timeWords,
    required this.am,
    required this.pm,
    required this.halfWords,
    required this.guardedAbbreviations,
    required this.every,
    required this.everyOne,
    required this.weekdayAll,
    required this.ordinals,
    required this.ordinalArticles,
    required this.ordinalOf,
    required this.ofMonthWords,
    required this.ordinalsBeforeWeekday,
    required this.andWords,
    required this.afterCompletion,
    required this.untilWords,
    required this.timesWords,
    required this.everyOther,
    required this.everyOtherAround,
    required this.weekOnWords,
    required this.repeatWords,
    required this.startWords,
    required this.monthTextBefore,
    required this.remindWords,
    required this.beforeWords,
    required this.afterWords,
  });

  /// BCP 47 primary language subtag.
  final String code;

  /// Default interpretation of an ambiguous numeric date such as 12/11.
  final DayMonthOrder dayMonthOrder;

  /// Relative day phrases → offset in days from today (never negative).
  final Map<String, int> dayWords;

  /// Index 0 = Monday … 6 = Sunday; names and abbreviations.
  final List<List<String>> weekdays;

  /// Index 0 = January … 11 = December.
  final List<MonthVocab> months;

  /// Words that may precede a date phrase and are swallowed with it ("on", "am", "le").
  final List<String> before;

  /// Words directly before a date phrase that make it the deadline (deadlines D7).
  final List<String> deadlineWords;

  /// "by" words, also in [before]: directly before a date phrase they make it the
  /// deadline, unless a time follows the date.
  final List<String> byWords;

  /// Words that park a task when the line has no date (someday-and-evening D6).
  final List<String> somedayWords;

  /// Time sector phrases by the sector they mean (time-sectors D8).
  final Map<String, List<String>> sectorPhrases;

  /// Words that make a task due today and for This Evening ("tonight").
  final List<String> eveningWords;

  final List<String> morningWords;
  final List<String> afternoonWords;

  /// Part words by part: morning, afternoon, evening.
  final Map<String, List<String>> partWords;

  /// "next" placed before the noun ("next Wed", "nächsten Mittwoch").
  final List<String> nextBefore;

  /// "next" placed after the noun ("mardi prochain", "martes que viene").
  final List<String> nextAfter;

  /// "this" placed before the noun; resolves like the bare weekday.
  final List<String> thisBefore;

  /// "in" for "in N days" ("in", "dans", "tra", "en", "em").
  final List<String> inWords;

  /// Words meaning one, for "in a week".
  final List<String> oneWords;

  final Units units;

  /// "of" between day and month ("3 of February", "3 de febrero").
  final List<String> ofWords;

  /// "at" before a time ("at", "um", "à", "alle", "a las", "às").
  final List<String> atWords;

  /// Hour marker after a number ("15 Uhr", "15 heures").
  final List<String> hourWords;

  /// Whether a bare "15h" / "15h30" token is a time in this language.
  final bool hourSuffixH;

  /// Named times of day → "HH:MM".
  final Map<String, String> timeWords;

  final List<String> am;
  final List<String> pm;

  /// "half" before an hour: half an hour before it, Dutch "om half 4" = 03:30.
  final List<String> halfWords;

  /// Weekday abbreviations that are also ordinary words (Dutch "ma", "zo").
  final List<String> guardedAbbreviations;

  // ---- recurrence phrases (quick-add-recurrence, design D2) ----

  /// Words that start a recurrence phrase ("every", "jeden", "tous les").
  final List<String> every;

  /// One-word recurrence forms → the English pattern after "every" ("daily" → "day").
  final Map<String, String> everyOne;

  /// The collective weekday word ("weekday", "werktags", "jours ouvrés").
  final List<String> weekdayAll;

  /// Ordinal words → 1–4, or -1 for last.
  final Map<String, int> ordinals;

  /// Articles before an ordinal weekday ("the", "den").
  final List<String> ordinalArticles;

  /// "of" between an ordinal weekday and a month ("of", "im", "de", "di").
  final List<String> ordinalOf;

  /// "of the month" after an ordinal weekday or a monthly rule.
  final List<String> ofMonthWords;

  /// Weekday names that are also ordinals, only directly before a weekday.
  final Map<String, int> ordinalsBeforeWeekday;

  /// "and" between weekdays.
  final List<String> andWords;

  /// "after completion".
  final List<String> afterCompletion;

  /// "until" before a date phrase.
  final List<String> untilWords;

  /// "for N times": words before and after the count.
  final TimesWords timesWords;

  /// "every other" before a unit or a weekday.
  final List<String> everyOther;

  /// "every other" around the unit or weekday.
  final Around everyOtherAround;

  /// "on" between a week count and weekdays: "every 2 weeks on Saturday".
  final List<String> weekOnWords;

  /// Connectors directly before a recurrence phrase, removed with it.
  final List<String> repeatWords;

  /// Words before a date next to a recurrence phrase that start the series there.
  final List<String> startWords;

  /// Single words after which a month name alone stays text ("from September").
  final List<String> monthTextBefore;

  /// "remind me", "erinnere mich", "rappelle-moi".
  final List<String> remindWords;

  /// "before" / "after" after a reminder offset.
  final List<String> beforeWords;
  final List<String> afterWords;

  /// The word list a TS `v[field]` lookup reads (`wordsAt` and `anyPhraseAt`).
  List<String> listFor(String field) => switch (field) {
        'somedayWords' => somedayWords,
        'eveningWords' => eveningWords,
        'morningWords' => morningWords,
        'afternoonWords' => afternoonWords,
        'afterCompletion' => afterCompletion,
        'untilWords' => untilWords,
        'repeatWords' => repeatWords,
        'startWords' => startWords,
        _ => const [],
      };
}
