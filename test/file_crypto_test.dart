import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/e2ee/crypto.dart';

Uint8List _hex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16),
    ]);

void main() {
  final key = _hex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  final prefix = _hex('d0d1d2d3d4d5d6d7');
  const plaintext = 'The quick brown fox jumps over the lazy dog';

  test('the OTAT1 envelope matches the shared browser/Go vector', () {
    final sealed = encryptFileBytes(
      key: key,
      attachmentId: 'a1',
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      prefix: prefix,
      chunkSize: 16,
    );
    expect(
      sealed.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '4f5441543100000010d0d1d2d3d4d5d6d747f531902ce0ec3799864375278d25eb'
      '60f9a151acf541cfb02d46a104df903e489160fdca48183430010fe5b6fb940c64'
      '9c7645e3a056f4ca522a7c5c7fe63d351c12ad88a4977caed97cf9677d19807583'
      'ff31ee89466628f2c5',
    );
  });

  test('decrypting the vector returns the plaintext', () {
    final envelope = _hex(
      '4f5441543100000010d0d1d2d3d4d5d6d747f531902ce0ec3799864375278d25eb'
      '60f9a151acf541cfb02d46a104df903e489160fdca48183430010fe5b6fb940c64'
      '9c7645e3a056f4ca522a7c5c7fe63d351c12ad88a4977caed97cf9677d19807583'
      'ff31ee89466628f2c5',
    );
    expect(utf8.decode(decryptFileBytes(key: key, attachmentId: 'a1', envelope: envelope)), plaintext);
  });

  test('round trips empty and exact-chunk files, and rejects altered bytes', () {
    final empty = encryptFileBytes(key: key, attachmentId: 'a2', plaintext: Uint8List(0), prefix: prefix, chunkSize: 16);
    expect(decryptFileBytes(key: key, attachmentId: 'a2', envelope: empty), isEmpty);

    final exact = Uint8List.fromList(utf8.encode('y' * 32));
    final sealed = encryptFileBytes(key: key, attachmentId: 'a3', plaintext: exact, prefix: prefix, chunkSize: 16);
    expect(decryptFileBytes(key: key, attachmentId: 'a3', envelope: sealed), exact);

    final altered = Uint8List.fromList(sealed)..[20] ^= 1;
    expect(
      () => decryptFileBytes(key: key, attachmentId: 'a3', envelope: altered),
      throwsA(isA<E2eeError>()),
    );
    expect(
      () => decryptFileBytes(key: key, attachmentId: 'other', envelope: sealed),
      throwsA(isA<E2eeError>()),
    );
    expect(
      () => decryptFileBytes(key: key, attachmentId: 'a3', envelope: Uint8List.sublistView(sealed, 0, sealed.length - 4)),
      throwsA(isA<E2eeError>()),
    );
  });

  test('a file larger than one chunk round trips', () {
    final bytes = Uint8List.fromList(List<int>.generate(fileChunkSize + 123, (i) => i % 251));
    final sealed = encryptFileBytes(key: key, attachmentId: 'big', plaintext: bytes);
    expect(sealed.length, bytes.length + 17 + 32);
    expect(decryptFileBytes(key: key, attachmentId: 'big', envelope: sealed), bytes);
  });
}
