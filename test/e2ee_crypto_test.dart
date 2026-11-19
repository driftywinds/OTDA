// The shared known-answer vectors from internal/e2ee and web/src/lib/crypto: if any
// of these drift, this client would write values no other client can read.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/e2ee/crypto.dart';

Uint8List hex(String text) {
  final out = <int>[];
  for (var i = 0; i < text.length; i += 2) {
    out.add(int.parse(text.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(out);
}

String toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

void main() {
  test('content vectors: the wire format matches byte for byte', () {
    const cases = [
      (
        key: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
        nonce: 'a0a1a2a3a4a5a6a7a8a9aaab',
        entity: 'task',
        entityId: 't1',
        field: 'title',
        plaintext: 'Dentist',
        value: 'enc:v1:oKGio6Slpqeoqaqron0SWSy4dh8xioWkMvJuPN5GjNypnM8',
      ),
    ];
    for (final c in cases) {
      final encrypted = encryptValue(
        key: hex(c.key),
        entity: c.entity,
        entityId: c.entityId,
        field: c.field,
        plaintext: c.plaintext,
        nonce: hex(c.nonce),
      );
      expect(encrypted, c.value);
      expect(
        decryptValue(
          key: hex(c.key),
          entity: c.entity,
          entityId: c.entityId,
          field: c.field,
          value: encrypted,
        ),
        c.plaintext,
      );
    }
  });

  test('a value moved to another field fails, as the binding requires', () {
    final key = Uint8List(32);
    final value = encryptValue(
      key: key,
      entity: 'task',
      entityId: 't1',
      field: 'title',
      plaintext: 'Dentist',
    );
    expect(
      () => decryptValue(key: key, entity: 'task', entityId: 't2', field: 'title', value: value),
      throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'cannot_decrypt')),
    );
    expect(
      () => decryptValue(key: key, entity: 'task', entityId: 't1', field: 'description', value: value),
      throwsA(isA<E2eeError>()),
    );
  });

  test('AES-KW matches the shared passphrase vector', () {
    final salt = hex('101112131415161718191a1b1c1d1e1f');
    final kek = derivePassphraseKey('correct horse battery staple', salt, 1000);
    final accountKey = hex('404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f');
    final wrapped = aesKeyWrap(kek, accountKey);
    expect(b64url(wrapped), 'IhPkjEwMwQjIq6ZCtz4_Qy82U3YOqmvFEdWDSV6W3c8-ToyYBwgXbA');
    expect(toHex(aesKeyUnwrap(kek, wrapped)), toHex(accountKey));
  });

  test('AES-KW matches RFC 3394 section 4.6', () {
    final kek = hex('000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F');
    final key = hex('00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F');
    expect(
      toHex(aesKeyWrap(kek, key)),
      '28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21',
    );
  });

  test('recovery text and its wrapping key match the shared vector', () {
    final raw = hex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
    expect(
      recoveryKeyToText(raw),
      'QCAY-FA4E-QWDI-PCEJ-RKFY-ZDMO-R6IJ-DEUT-SSKZ-NF4Y-TGNJ-XHE5-T2PQ-QLMG',
    );
    expect(toHex(recoveryKeyFromText('qcay fa4e qwdi pcej rkfy zdmo r6ij deut sskz nf4y tgnj xhe5 t2pq qlmg')), toHex(raw));

    final accountKey = hex('404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f');
    final kek = deriveRecoveryKey(raw);
    expect(b64url(aesKeyWrap(kek, accountKey)), 'LCFihcp0aqAZBq7Cl9C3ZQbzk03iDPjbEPS6-nUmlKdywd1DzgriFw');
    expect(toHex(aesKeyUnwrap(kek, aesKeyWrap(kek, accountKey))), toHex(accountKey));
  });

  test('a mistyped recovery key is rejected, not decrypted', () {
    final raw = hex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
    final text = recoveryKeyToText(raw);
    final bad = text.substring(0, text.length - 1) + (text.endsWith('A') ? 'B' : 'A');
    expect(
      () => recoveryKeyFromText(bad),
      throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'bad_recovery_key')),
    );
  });

  test('iterations outside the accepted range stay locked', () {
    expect(() => checkIterations(99999), throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'bad_iterations')));
    expect(() => checkIterations(20000000), throwsA(isA<E2eeError>()));
    expect(() => checkIterations(600000), returnsNormally);
  });

  test('a fresh nonce makes each ciphertext different', () {
    final key = Uint8List(32);
    final a = encryptValue(key: key, entity: 'task', entityId: 't', field: 'title', plaintext: 'same');
    final b = encryptValue(key: key, entity: 'task', entityId: 't', field: 'title', plaintext: 'same');
    expect(a, isNot(b));
    expect(isEnvelope(a), isTrue);
    expect(isEnvelope('plain'), isFalse);
  });
}
