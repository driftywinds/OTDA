import 'package:shared_preferences/shared_preferences.dart';

/// A small persistent log for reminders and the widget.
///
/// It lives in SharedPreferences, not in memory, so lines written by the
/// notification-button and widget background isolates show up next to the app's own.
class DebugLog {
  DebugLog._();

  static const _key = 'debug.log';
  static const _max = 300;

  static String _stamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static Future<void> add(String line, {String source = 'app'}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final lines = prefs.getStringList(_key) ?? <String>[];
      lines.add('${_stamp()} [$source] $line');
      if (lines.length > _max) lines.removeRange(0, lines.length - _max);
      await prefs.setStringList(_key, lines);
    } on Object {
      // logging must never break what it is logging
    }
  }

  static Future<List<String>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getStringList(_key) ?? const [];
    } on Object {
      return const [];
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } on Object {
      // nothing to clear
    }
  }
}
