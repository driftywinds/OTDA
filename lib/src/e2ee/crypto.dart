import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The end-to-end encryption primitives, matching the server's spec and the shared
/// vectors (`web/src/lib/e2ee.vectors.json`):
///
///   value    = "enc:v1:" + b64url(nonce(12) || AES-256-GCM(utf8(plaintext)) || tag(16))
///   aad      = utf8(entity + "\0" + entityId + "\0" + field)
///   wrapped  = b64url(AES-KW-256(accountKey)) under a PBKDF2 or HKDF key
const prefixV1 = 'enc:v1:';
const pbkdf2Iterations = 600000;
const acceptedIterationsMin = 600000;
const acceptedIterationsMax = 10000000;
const recoveryInfo = 'opentodo/e2ee/recovery-kek/v1';

const _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// A failure worth showing: `cannot_decrypt` is the "[Cannot decrypt]" case, which
/// keeps the operation instead of dropping the row.
class E2eeError implements Exception {
  const E2eeError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

Uint8List randomBytes(int count) {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(count, (_) => random.nextInt(256)));
}

Uint8List aadFor(String entity, String entityId, String field) =>
    Uint8List.fromList(utf8.encode('$entity\u0000$entityId\u0000$field'));

Uint8List _gcm({required bool encrypt, required Uint8List key, required Uint8List nonce, required List<int> data, required Uint8List aad}) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad));
  return cipher.process(Uint8List.fromList(data));
}

String b64url(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64url(String text) {
  final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
  return Uint8List.fromList(base64Url.decode(padded));
}

/// Encrypts one field value. [nonce] exists for the vectors; production always
/// generates a fresh 96-bit nonce.
String encryptValue({
  required Uint8List key,
  required String entity,
  required String entityId,
  required String field,
  required String plaintext,
  Uint8List? nonce,
}) {
  final n = nonce ?? randomBytes(12);
  final sealed = _gcm(
    encrypt: true,
    key: key,
    nonce: n,
    data: utf8.encode(plaintext),
    aad: aadFor(entity, entityId, field),
  );
  return '$prefixV1${b64url(Uint8List.fromList([...n, ...sealed]))}';
}

String decryptValue({
  required Uint8List key,
  required String entity,
  required String entityId,
  required String field,
  required String value,
}) {
  if (!value.startsWith(prefixV1)) {
    throw const E2eeError('not_encrypted', 'this value is not a ciphertext');
  }
  final raw = unb64url(value.substring(prefixV1.length));
  if (raw.length < 12 + 16) throw const E2eeError('cannot_decrypt', '[Cannot decrypt]');
  final nonce = Uint8List.sublistView(raw, 0, 12);
  final sealed = Uint8List.sublistView(raw, 12);
  try {
    final plain = _gcm(
      encrypt: false,
      key: key,
      nonce: nonce,
      data: sealed,
      aad: aadFor(entity, entityId, field),
    );
    return utf8.decode(plain);
  } on Object {
    // Wrong key, a value moved to another field, or a tampered tag: the binding is
    // what tells them apart from a valid ciphertext.
    throw const E2eeError('cannot_decrypt', '[Cannot decrypt]');
  }
}

bool isEnvelope(Object? value) => value is String && value.startsWith('enc:');

// ---- key derivation -------------------------------------------------------

/// The accepted iteration range the app enforces on a key record. A broken or
/// hostile server must not be able to weaken the derivation or hang the device.
void checkIterations(int iterations) {
  if (iterations < acceptedIterationsMin || iterations > acceptedIterationsMax) {
    throw E2eeError('bad_iterations',
        'the key record from the server uses $iterations iterations, outside the accepted range');
  }
}

Uint8List derivePassphraseKey(String passphrase, Uint8List salt, int iterations) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
}

Uint8List deriveRecoveryKey(Uint8List raw) {
  final derivator = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(raw, 32, Uint8List(32), Uint8List.fromList(utf8.encode(recoveryInfo))));
  return derivator.process(Uint8List(0));
}

// ---- AES-KW (RFC 3394) ----------------------------------------------------
// PointyCastle 4 has no key wrap, so the 64-bit-block variant is here, checked
// against RFC 3394 4.6 and the shared vectors.

const _kwIv = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6];

Uint8List _aesBlock(Uint8List key, bool encrypt, Uint8List block) {
  final cipher = AESEngine()..init(encrypt, KeyParameter(key));
  final out = Uint8List(16);
  cipher.processBlock(block, 0, out, 0);
  return out;
}

Uint8List aesKeyWrap(Uint8List kek, Uint8List plain) {
  if (plain.isEmpty || plain.length % 8 != 0) {
    throw ArgumentError('AES-KW needs a multiple of 8 bytes');
  }
  final n = plain.length ~/ 8;
  final a = Uint8List.fromList(_kwIv);
  final r = [for (var i = 0; i < n; i++) Uint8List.fromList(plain.sublist(i * 8, i * 8 + 8))];
  for (var j = 0; j < 6; j++) {
    for (var i = 0; i < n; i++) {
      final block = Uint8List(16)
        ..setAll(0, a)
        ..setAll(8, r[i]);
      final out = _aesBlock(kek, true, block);
      a.setAll(0, out.sublist(0, 8));
      final t = n * j + i + 1;
      for (var k = 0; k < 8; k++) {
        a[7 - k] ^= (t >> (8 * k)) & 0xff;
      }
      r[i] = out.sublist(8, 16);
    }
  }
  return Uint8List.fromList([...a, for (final block in r) ...block]);
}

Uint8List aesKeyUnwrap(Uint8List kek, Uint8List wrapped) {
  if (wrapped.length < 24 || wrapped.length % 8 != 0) {
    throw const E2eeError('bad_key_record', 'the wrapped key is malformed');
  }
  final n = wrapped.length ~/ 8 - 1;
  final a = Uint8List.fromList(wrapped.sublist(0, 8));
  final r = [for (var i = 0; i < n; i++) Uint8List.fromList(wrapped.sublist(8 + i * 8, 16 + i * 8))];
  for (var j = 5; j >= 0; j--) {
    for (var i = n - 1; i >= 0; i--) {
      final t = n * j + i + 1;
      for (var k = 0; k < 8; k++) {
        a[7 - k] ^= (t >> (8 * k)) & 0xff;
      }
      final block = Uint8List(16)
        ..setAll(0, a)
        ..setAll(8, r[i]);
      final out = _aesBlock(kek, false, block);
      a.setAll(0, out.sublist(0, 8));
      r[i] = out.sublist(8, 16);
    }
  }
  for (var i = 0; i < 8; i++) {
    if (a[i] != _kwIv[i]) {
      throw const E2eeError('wrong_secret', 'the passphrase or recovery key is not correct');
    }
  }
  return Uint8List.fromList([for (final block in r) ...block]);
}

// ---- recovery key text ----------------------------------------------------

String _base32(Uint8List bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out.write(_base32Alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    // Keep only the bits that have not been emitted: an int is 64-bit and would
    // otherwise drop the high order of a long input.
    buffer &= bits == 0 ? 0 : (1 << bits) - 1;
  }
  if (bits > 0) out.write(_base32Alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List _fromBase32(String text) {
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in text.toUpperCase().split('')) {
    final value = _base32Alphabet.indexOf(char);
    if (value < 0) throw const E2eeError('bad_recovery_key', 'this is not a valid recovery key');
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
    buffer &= bits == 0 ? 0 : (1 << bits) - 1;
  }
  return Uint8List.fromList(out);
}

String _recoveryChecksum(Uint8List raw) =>
    _base32(Uint8List.fromList(SHA256Digest().process(raw).sublist(0, 3))).substring(0, 4);

/// 52 base32 characters of the key plus 4 of checksum, in groups of four.
String recoveryKeyToText(Uint8List raw) {
  final body = _base32(raw);
  final text = '$body${_recoveryChecksum(raw)}';
  return [for (var i = 0; i < text.length; i += 4) text.substring(i, i + 4)].join('-');
}

Uint8List recoveryKeyFromText(String text) {
  final clean = text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (clean.length != 56) throw const E2eeError('bad_recovery_key', 'this is not a valid recovery key');
  final body = clean.substring(0, 52);
  final given = clean.substring(52);
  final raw = _fromBase32(body);
  if (raw.length != 32 || _recoveryChecksum(raw) != given) {
    throw const E2eeError('bad_recovery_key', 'this is not a valid recovery key');
  }
  return raw;
}
