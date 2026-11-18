import 'dart:convert';

/// Cookies for one server, kept in memory and persisted with the session.
///
/// `package:http` hands every `Set-Cookie` back joined into one string, so the
/// values are split on the comma that starts the next `name=` pair. Attributes
/// (Expires, Max-Age) are not tracked: a session lives 90 days by default and a
/// dead one answers 401, which is the signal that matters.
/// shortcut: cookie expiry is not tracked, clear on 401 instead.
class CookieJar {
  CookieJar([Map<String, String>? initial]) : _cookies = {...?initial};

  final Map<String, String> _cookies;

  /// Splits a joined `Set-Cookie` value into single cookies.
  static final _next = RegExp(r',\s*(?=[A-Za-z0-9_\-]+=)');

  bool get isEmpty => _cookies.isEmpty;

  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  String? get header => _cookies.isEmpty
      ? null
      : _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void absorb(Object? value) {
    for (final raw in _split(value)) {
      final pair = raw.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final val = pair.substring(eq + 1).trim();
      final expired = raw.toLowerCase().contains('max-age=0');
      if (val.isEmpty || expired) {
        _cookies.remove(name);
      } else {
        _cookies[name] = val;
      }
    }
  }

  Iterable<String> _split(Object? value) sync* {
    if (value is List) {
      for (final v in value) {
        yield* _split(v);
      }
      return;
    }
    final text = value?.toString() ?? '';
    if (text.isEmpty) return;
    yield* text.split(_next);
  }

  void clear() => _cookies.clear();

  String toJson() => jsonEncode(_cookies);

  static CookieJar fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return CookieJar();
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        return CookieJar(map.map((k, v) => MapEntry(k.toString(), v.toString())));
      }
    } on FormatException {
      // a corrupt jar is the same as no session
    }
    return CookieJar();
  }
}
