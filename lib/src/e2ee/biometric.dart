import 'dart:convert';

import 'package:crypto/crypto.dart' as digest;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto.dart';
import 'keys.dart';

/// The writable seam for tests: the platform keystore in production.
abstract interface class BiometricBackend {
  Future<void> writeIdentity(String value);
  Future<String?> readIdentity();
  Future<void> deleteIdentity();
  Future<void> writeKey(String value);
  Future<String?> readKey();
  Future<void> deleteKey();
}

/// Android: a Keystore-backed AES key that requires biometric authentication;
/// iOS: a Keychain item gated by `userPresence` (Face ID / Touch ID / passcode).
class SecureBiometricBackend implements BiometricBackend {
  SecureBiometricBackend();

  static const _identitySlot = 'e2ee.biometricFor';
  static const _keySlot = 'e2ee.biometricKey';

  final _plain = const FlutterSecureStorage();
  final _protected = const FlutterSecureStorage(
    aOptions: AndroidOptions.biometric(
      // The plugin isolates keys per namespace. Without this, the plain
      // identity store and the biometric store share the default namespace,
      // so the biometric read reuses the non-biometric key and never prompts.
      storageNamespace: 'otda_biometric',
      enforceBiometrics: true,
      requireBiometricsPerOperation: true,
      biometricPromptTitle: 'Unlock OTDA',
      biometricPromptSubtitle: 'Use your fingerprint or face to unlock encryption',
    ),
    iOptions: IOSOptions(
      accessControlFlags: [AccessControlFlag.userPresence],
    ),
  );

  @override
  Future<void> writeIdentity(String value) => _plain.write(key: _identitySlot, value: value);

  @override
  Future<String?> readIdentity() => _plain.read(key: _identitySlot);

  @override
  Future<void> deleteIdentity() => _plain.delete(key: _identitySlot);

  @override
  Future<void> writeKey(String value) => _protected.write(key: _keySlot, value: value);

  @override
  Future<String?> readKey() => _protected.read(key: _keySlot);

  @override
  Future<void> deleteKey() => _protected.delete(key: _keySlot);
}

/// Fingerprint/face unlock for an encrypted account: the account key is kept in
/// the platform keystore under a biometric-gated key, next to the identity of the
/// key record it belongs to. Changing biometrics generally invalidates the
/// platform key; the next read throws and the copy is dropped.
class BiometricUnlock {
  BiometricUnlock({BiometricBackend? backend, this.supportedOverride})
      : _backend = backend ?? SecureBiometricBackend();

  static final instance = BiometricUnlock();

  final BiometricBackend _backend;
  final bool? supportedOverride;

  bool get supported =>
      supportedOverride ?? (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS));

  /// Whether this account key has a wrapped copy here. Reads only the non-secret
  /// identity slot, so it never prompts.
  Future<bool> enrolled(KeyRecord record) async {
    if (!supported) return false;
    try {
      return await _backend.readIdentity() == _identity(record);
    } on Object {
      return false;
    }
  }

  Future<void> enable(Uint8List accountKey, KeyRecord record) async {
    if (!supported) return;
    final id = _identity(record);
    await _backend.writeKey(jsonEncode({'key': b64url(accountKey), 'id': id}));
    await _backend.writeIdentity(id);
    try {
      // Writing the protected item alone does not prove the OS will accept a
      // biometric prompt later. Reading it back forces that prompt now, so
      // "enabled" only appears after the fingerprint/face actually resolves.
      final raw = await _backend.readKey();
      final map = raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (map == null || map['id'] != id || map['key'] != b64url(accountKey)) {
        throw StateError('biometric copy did not survive the round trip');
      }
    } on Object {
      await disable();
      rethrow;
    }
  }

  /// A stable identity for the key record. `createdAt` was not reliable (older
  /// records report 0), and including the wrapped material invalidates the copy
  /// when the passphrase is changed.
  String _identity(KeyRecord record) => digest.sha256
      .convert(utf8.encode('${record.salt}|${record.wrappedByPassphrase}|${record.createdAt}'))
      .toString();

  /// Unwraps the key. A copy belonging to another key record is deleted rather
  /// than used, and a keystore that invalidated the key (biometrics changed) is
  /// cleaned up too.
  Future<Uint8List?> read(KeyRecord record) async {
    if (!supported) return null;
    final id = _identity(record);
    final String? stored;
    try {
      stored = await _backend.readIdentity();
    } on Object {
      return null;
    }
    if (stored == null) return null;
    if (stored != id) {
      await disable();
      return null;
    }
    try {
      final raw = await _backend.readKey();
      if (raw == null) {
        await disable();
        return null;
      }
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (map['id'] != id) {
        await disable();
        return null;
      }
      final key = map['key']?.toString() ?? '';
      return key.isEmpty ? null : unb64url(key);
    } on Object {
      await disable();
      return null;
    }
  }

  Future<void> disable() async {
    try {
      await _backend.deleteKey();
    } on Object {
      // already gone
    }
    try {
      await _backend.deleteIdentity();
    } on Object {
      // already gone
    }
  }
}
