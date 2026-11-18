import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/api/cookie_jar.dart';

void main() {
  group('CookieJar', () {
    test('parses one cookie with attributes', () {
      final jar = CookieJar()
        ..absorb('opentodo_session=abc123; Path=/; Expires=Tue, 16 Feb 2027 13:14:01 GMT; HttpOnly; SameSite=Lax');
      expect(jar.cookies['opentodo_session'], 'abc123');
      expect(jar.header, 'opentodo_session=abc123');
    });

    test('splits several cookies joined by http into one string', () {
      final jar = CookieJar()
        ..absorb('opentodo_session=abc; Path=/; Expires=Tue, 16 Feb 2027 13:14:01 GMT; HttpOnly, ot_trust=xyz; Path=/; HttpOnly');
      expect(jar.cookies, {'opentodo_session': 'abc', 'ot_trust': 'xyz'});
      expect(jar.header, 'opentodo_session=abc; ot_trust=xyz');
    });

    test('drops a cookie cleared with Max-Age=0', () {
      final jar = CookieJar({'opentodo_session': 'abc'})
        ..absorb('opentodo_session=; Path=/; Max-Age=0; HttpOnly');
      expect(jar.isEmpty, isTrue);
    });

    test('survives a round trip through json', () {
      final jar = CookieJar({'a': '1', 'b': '2'});
      expect(CookieJar.fromJson(jar.toJson()).cookies, jar.cookies);
    });

    test('a corrupt record reads as signed out', () {
      expect(CookieJar.fromJson('not json').isEmpty, isTrue);
    });
  });

  group('ApiException', () {
    test('reads the documented error envelope', () {
      final e = ApiException.fromBody(403, '{"error":{"code":"insufficient_scope","message":"nope"}}');
      expect(e.status, 403);
      expect(e.code, 'insufficient_scope');
      expect(e.isForbidden, isTrue);
      expect(e.needsReauth, isFalse);
    });

    test('recognises the step-up refusal', () {
      final e = ApiException.fromBody(403, '{"error":{"code":"reauth_required","message":"confirm"}}');
      expect(e.needsReauth, isTrue);
    });

    test('falls back when the body is not the envelope', () {
      final e = ApiException.fromBody(502, '<html>bad gateway</html>');
      expect(e.code, 'http_502');
    });
  });
}
