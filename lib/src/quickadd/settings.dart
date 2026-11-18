// The pure part of the per-device quick-add preferences, ported from
// web/src/lib/nlp/settings.ts (OpenTodo v1.5.0). The storage functions of that
// file (loadQuickAddSettings, saveQuickAddSettings, onQuickAddSettingsChange) are
// browser localStorage, so they are not ported; the app owns its own settings.
import 'vocab/index.dart';

class QuickAddSettings {
  const QuickAddSettings({this.enabled = true, this.languages});

  /// Parse natural language in quick add.
  final bool enabled;

  /// Explicit language list, or null to follow the device's preferred languages.
  final List<String>? languages;
}

const QuickAddSettings defaultQuickAddSettings = QuickAddSettings();

/// The language tags handed to the parser: the device's explicit list, else the
/// interface language (omitted or 'system' when none is chosen) followed by the
/// device's languages. English is always active.
List<String> resolveLanguages(QuickAddSettings s, List<String> device, [String? language]) {
  if (s.languages != null) return activeLanguages(s.languages!);
  return activeLanguages(language != null && language != 'system' ? [language, ...device] : device);
}

/// What decided the numeric date order.
enum DayMonthOrderSource { dateFormat, language }

/// Numeric date order and what decided it: the user's date format when it is
/// day-month or month-day, else the language rule for iso and system.
({DayMonthOrder order, DayMonthOrderSource source}) dayMonthOrderSource(
  QuickAddSettings s,
  List<String> device, [
  Map<String, Object?>? prefs,
]) {
  final format = prefs?['date_format'];
  if (format == 'day-month') return (order: DayMonthOrder.dm, source: DayMonthOrderSource.dateFormat);
  if (format == 'month-day') return (order: DayMonthOrder.md, source: DayMonthOrderSource.dateFormat);
  return (order: _languageDayMonthOrder(s, device), source: DayMonthOrderSource.language);
}

/// Numeric date order: the date format preference, else M/D only when the first
/// preference is US-style English ("en", "en-US"), D/M for every other bundled
/// language and for English outside the US.
DayMonthOrder resolveDayMonthOrder(QuickAddSettings s, List<String> device, [Map<String, Object?>? prefs]) =>
    dayMonthOrderSource(s, device, prefs).order;

DayMonthOrder _languageDayMonthOrder(QuickAddSettings s, List<String> device) {
  String? first;
  if (s.languages != null) {
    if (s.languages!.isNotEmpty) first = s.languages![0];
  } else {
    for (final t in device) {
      if (vocabularies.containsKey(t.toLowerCase().split(RegExp('[-_]')).first)) {
        first = t;
        break;
      }
    }
  }
  first ??= 'en';
  final parts = first.toLowerCase().split(RegExp('[-_]'));
  final lang = parts[0];
  final region = parts.length > 1 ? parts[1] : null;
  if (lang == 'en') return region == null || region == 'us' ? DayMonthOrder.md : DayMonthOrder.dm;
  return vocabularies[lang]?.dayMonthOrder ?? DayMonthOrder.md;
}

/// `45` → `45m`, `90` → `1h30m`, `120` → `2h`.
String formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return m != 0 ? '${h}h${m}m' : '${h}h';
}
