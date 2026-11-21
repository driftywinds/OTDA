@Tags(['integration'])
library;

// Exercises the second-factor routes against a real v1.5.0 server:
//
//   flutter test test/mfa_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// It enrols, confirms with a TOTP code computed here, checks the recovery-code
// count, lists and forgets remembered browsers, regenerates the codes and turns
// the factor off again. Run it on a scratch account: it changes the account's
// second factor.
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/auth/mfa_service.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18081');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'perf@example.com');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'perf-password-10k');

void main() {
  test('the second factor can be enrolled, inspected and turned off', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');
    const mfa = MfaService();

    // A previous run may have left it on; start from off.
    var status = await mfa.status(client);
    if (status.enrolled) await mfa.disable(client);
    status = await mfa.status(client);
    expect(status.enrolled, isFalse);
    expect(status.restricted, isFalse);

    final enrolment = await mfa.enroll(client);
    expect(enrolment.secret, isNotEmpty);
    expect(enrolment.uri, startsWith('otpauth://totp/'));

    final confirmation = await mfa.confirm(client, _totp(enrolment.secret));
    expect(confirmation.recoveryCodes, hasLength(10));
    expect(confirmation.status.enrolled, isTrue);
    expect(confirmation.status.recoveryCodesRemaining, 10);

    status = await mfa.status(client);
    expect(status.enrolled, isTrue);
    expect(status.recoveryCodesRemaining, 10);
    expect(status.policy, anyOf('none', 'owner', 'all'));

    final devices = await mfa.trustedDevices(client);
    expect(devices, isNotNull);
    await mfa.forgetAllTrustedDevices(client);

    final regenerated = await mfa.regenerateRecoveryCodes(client);
    expect(regenerated, hasLength(10));
    expect(regenerated, isNot(equals(confirmation.recoveryCodes)));

    await mfa.disable(client);
    status = await mfa.status(client);
    expect(status.enrolled, isFalse);

    client.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A current six-digit TOTP code (RFC 6238, SHA-1, 30 s step).
String _totp(String base32Secret) {
  final key = _base32(base32Secret);
  var counter = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ 30;
  final message = List<int>.filled(8, 0);
  for (var i = 7; i >= 0; i--) {
    message[i] = counter & 0xff;
    counter >>= 8;
  }
  final digest = Hmac(sha1, key).convert(message).bytes;
  final offset = digest.last & 0x0f;
  final value = ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
  return (value % 1000000).toString().padLeft(6, '0');
}

List<int> _base32(String text) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var buffer = 0;
  var bits = 0;
  final out = <int>[];
  for (final char in text.toUpperCase().replaceAll('=', '').split('')) {
    final value = alphabet.indexOf(char);
    if (value < 0) continue;
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return out;
}
