import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

/// What the server stores for an encrypted account: only wrapped key material and
/// the derivation parameters. It never receives the passphrase, the recovery key or
/// the account key.
class KeyRecord {
  const KeyRecord({
    this.version = 1,
    this.kdf = kdfPbkdf2Sha256,
    required this.salt,
    required this.iterations,
    required this.wrappedByPassphrase,
    required this.wrappedByRecovery,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  factory KeyRecord.fromJson(Map<String, Object?> json) => KeyRecord(
        version: (json['version'] as num?)?.toInt() ?? 0,
        kdf: (json['kdf'] as num?)?.toInt() ?? 0,
        salt: json['salt']?.toString() ?? '',
        iterations: (json['iterations'] as num?)?.toInt() ?? 0,
        wrappedByPassphrase: json['wrappedByPassphrase']?.toString() ?? '',
        wrappedByRecovery: json['wrappedByRecovery']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  static const kdfPbkdf2Sha256 = 1;

  final int version;
  final int kdf;
  final String salt;
  final int iterations;
  final String wrappedByPassphrase;
  final String wrappedByRecovery;

  /// When the account's key was first created. A re-wrap (passphrase change)
  /// keeps it, so it identifies the account key rather than a record version.
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toJson() => {
        'version': version,
        'kdf': kdf,
        'salt': salt,
        'iterations': iterations,
        'wrappedByPassphrase': wrappedByPassphrase,
        'wrappedByRecovery': wrappedByRecovery,
      };

  /// Refuses a record this client cannot trust: an unknown format, or a derivation
  /// count outside the accepted range, keeps the device locked with an error rather
  /// than deriving with it.
  void validate({bool checkRange = true}) {
    if (version != 1 || kdf != kdfPbkdf2Sha256) {
      throw E2eeError('bad_key_record', 'the server sent a key record this app does not understand');
    }
    if (checkRange) checkIterations(iterations);
    if (unb64url(salt).length != 16) {
      throw const E2eeError('bad_key_record', 'the key record has a malformed salt');
    }
    if (unb64url(wrappedByPassphrase).length != 40 || unb64url(wrappedByRecovery).length != 40) {
      throw const E2eeError('bad_key_record', 'the key record has malformed wrapped keys');
    }
  }
}

/// A record made on this device, before anything leaves it.
class NewKeyRecord {
  const NewKeyRecord({required this.record, required this.accountKey, required this.recoveryKey});

  final KeyRecord record;
  final Uint8List accountKey;

  /// Shown once, then never stored: 56 base32 characters in groups of four.
  final String recoveryKey;
}

/// Enables encryption for the account: a fresh account key wrapped under both the
/// passphrase and a new recovery key.
///
/// shortcut: the passphrase is not NFC-normalised (no Unicode normalisation in the
/// Dart core). ASCII and precomposed text are unaffected; a decomposed passphrase
/// typed on another client would unwrap to a different key.
NewKeyRecord createKeyRecord(String passphrase, {int iterations = pbkdf2Iterations}) {
  if (passphrase.length < 12) {
    throw const E2eeError('weak_passphrase', 'use a passphrase of at least 12 characters');
  }
  final accountKey = randomBytes(32);
  final salt = randomBytes(16);
  final recoveryRaw = randomBytes(32);

  final passphraseKek = derivePassphraseKey(passphrase, salt, iterations);
  final recoveryKek = deriveRecoveryKey(recoveryRaw);

  return NewKeyRecord(
    accountKey: accountKey,
    recoveryKey: recoveryKeyToText(recoveryRaw),
    record: KeyRecord(
      salt: b64url(salt),
      iterations: iterations,
      wrappedByPassphrase: b64url(aesKeyWrap(passphraseKek, accountKey)),
      wrappedByRecovery: b64url(aesKeyWrap(recoveryKek, accountKey)),
    ),
  );
}

Uint8List unlockWithPassphrase(KeyRecord record, String passphrase, {bool strict = true}) {
  record.validate(checkRange: strict);
  final kek = derivePassphraseKey(passphrase, unb64url(record.salt), record.iterations);
  return aesKeyUnwrap(kek, unb64url(record.wrappedByPassphrase));
}

Uint8List unlockWithRecoveryKey(KeyRecord record, String text, {bool strict = true}) {
  record.validate(checkRange: strict);
  final recoveryRaw = recoveryKeyFromText(text);
  final kek = deriveRecoveryKey(recoveryRaw);
  return aesKeyUnwrap(kek, unb64url(record.wrappedByRecovery));
}

/// Change passphrase: re-wraps the same account key, so no content is re-encrypted
/// and other devices keep working.
KeyRecord rewrapWithPassphrase(
  KeyRecord record,
  String current,
  String next, {
  int iterations = pbkdf2Iterations,
  bool strict = true,
}) {
  final accountKey = unlockWithPassphrase(record, current, strict: strict);
  if (next.length < 12) {
    throw const E2eeError('weak_passphrase', 'use a passphrase of at least 12 characters');
  }
  final salt = randomBytes(16);
  final passphraseKek = derivePassphraseKey(next, salt, iterations);
  return KeyRecord(
    salt: b64url(salt),
    iterations: iterations,
    wrappedByPassphrase: b64url(aesKeyWrap(passphraseKek, accountKey)),
    wrappedByRecovery: record.wrappedByRecovery,
  );
}

/// Forgot the passphrase: the recovery key unwraps the account key and re-wraps it
/// under a new passphrase and a new recovery key. The old recovery key stops working.
({KeyRecord record, String recoveryKey}) resetWithRecoveryKey(
  KeyRecord record,
  String recoveryText,
  String nextPassphrase, {
  int iterations = pbkdf2Iterations,
  bool strict = true,
}) {
  final accountKey = unlockWithRecoveryKey(record, recoveryText, strict: strict);
  if (nextPassphrase.length < 12) {
    throw const E2eeError('weak_passphrase', 'use a passphrase of at least 12 characters');
  }
  final salt = randomBytes(16);
  final recoveryRaw = randomBytes(32);
  return (
    record: KeyRecord(
      salt: b64url(salt),
      iterations: iterations,
      wrappedByPassphrase: b64url(aesKeyWrap(derivePassphraseKey(nextPassphrase, salt, iterations), accountKey)),
      wrappedByRecovery: b64url(aesKeyWrap(deriveRecoveryKey(recoveryRaw), accountKey)),
    ),
    recoveryKey: recoveryKeyToText(recoveryRaw),
  );
}

/// The JSON a wrapped key travels as, for `GET /api/v1/encryption/keys`.
String encodeKeyRecord(KeyRecord record) => jsonEncode(record.toJson());
