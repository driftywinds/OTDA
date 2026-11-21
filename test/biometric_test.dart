import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/e2ee/biometric.dart';
import 'package:otda/src/e2ee/keys.dart';

class _MemoryBackend implements BiometricBackend {
  String? identity;
  String? key;

  @override
  Future<void> writeIdentity(String value) async => identity = value;
  @override
  Future<String?> readIdentity() async => identity;
  @override
  Future<void> deleteIdentity() async => identity = null;
  @override
  Future<void> writeKey(String value) async => key = value;
  @override
  Future<String?> readKey() async => key;
  @override
  Future<void> deleteKey() async => key = null;
}

void main() {
  KeyRecord record(int createdAt) => KeyRecord(
        salt: 'c2FsdA',
        iterations: 600000,
        wrappedByPassphrase: 'cGFzcw',
        wrappedByRecovery: 'cmVjb3Y',
        createdAt: createdAt,
      );

  test('a key record carries its creation time but never writes it back', () {
    final parsed = KeyRecord.fromJson({
      'version': 1,
      'kdf': 1,
      'salt': 'c2FsdA',
      'iterations': 600000,
      'wrappedByPassphrase': 'cGFzcw',
      'wrappedByRecovery': 'cmVjb3Y',
      'createdAt': 1234,
      'updatedAt': 5678,
    });
    expect(parsed.createdAt, 1234);
    expect(parsed.updatedAt, 5678);
    expect(parsed.toJson().containsKey('createdAt'), isFalse);
  });

  test('the biometric copy belongs to one key record and is dropped with it', () async {
    final backend = _MemoryBackend();
    final unlock = BiometricUnlock(backend: backend, supportedOverride: true);
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final first = record(100);

    expect(await unlock.enrolled(first), isFalse);
    await unlock.enable(key, first);
    expect(await unlock.enrolled(first), isTrue);
    expect(await unlock.read(first), key);

    // A re-enabled account has a new record and a new key: the old copy must not
    // be used, even if the platform still returns it.
    final second = record(200);
    expect(await unlock.enrolled(second), isFalse);
    expect(await unlock.read(second), isNull);
    expect(backend.key, isNull, reason: 'a stale copy is deleted');

    await unlock.enable(key, first);
    await unlock.disable();
    expect(await unlock.enrolled(first), isFalse);
    expect(backend.identity, isNull);
    expect(backend.key, isNull);
  });

  test('a corrupt or invalidated keystore read is dropped, not thrown', () async {
    final backend = _MemoryBackend();
    final unlock = BiometricUnlock(backend: backend, supportedOverride: true);
    final first = record(100);
    await unlock.enable(Uint8List.fromList(List<int>.generate(32, (i) => i)), first);
    backend.key = jsonEncode({'key': 'not-base64!', 'createdAt': 100});
    expect(await unlock.read(first), isNull);
    expect(backend.key, isNull);
  });
}
