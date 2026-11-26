import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../data/db.dart';
import 'biometric.dart';
import 'crypto.dart';
import 'fields.dart';
import 'keys.dart' as k;
import 'log.dart';

/// The account is encrypted and this device holds no key: syncing must stop
/// before anything is applied, and the app asks for the passphrase.
class E2eeLockedException implements Exception {
  const E2eeLockedException();

  @override
  String toString() => 'the account is encrypted and this device is locked';
}

/// The device's view of the account's encryption: the wrapped record (from the
/// server or the last copy kept here) and, once unlocked, the account key.
///
/// The key lives in the platform keystore after the first unlock, so a normal app
/// open does not ask for the passphrase again. Signing out or turning encryption
/// off forgets it. App lock is separate: it gates the UI, not this key.
class E2eeSession {
  E2eeSession._();

  static final E2eeSession instance = E2eeSession._();
  static const _storage = FlutterSecureStorage();
  static const _keySlot = 'e2ee.accountKey';
  static const _recordSlot = 'e2ee.record';

  /// Tests use an in-memory replica and cannot reach the platform keystore.
  static bool persistToKeystore = true;

  k.KeyRecord? record;
  Uint8List? _accountKey;

  /// While false, outgoing values stay plaintext even though the key is held:
  /// turning encryption off keeps the key long enough to decrypt what is still
  /// ciphertext, then forgets it.
  bool _sealing = true;

  /// 0..1 while the stored ciphertext is decrypted after an unlock, null otherwise.
  final progress = ValueNotifier<double?>(null);

  bool get enabled => record != null;
  bool get unlocked => _accountKey != null;
  bool get sealing => _sealing && record != null;

  /// The key while unlocked, for wrapping it under biometrics.
  Uint8List? get accountKey => _accountKey;

  /// Reads the wrapped record. A 404 (or no record) means the account is not
  /// encrypted, which is the usual case.
  Future<k.KeyRecord?> fetchRecord(ApiClient client) async {
    e2eeLog('record: asking the server');
    try {
      final json = await client.get('/api/v1/encryption/keys').timeout(const Duration(seconds: 8));
      final map = json is Map ? json['keys'] : null;
      final fetched = map is Map ? k.KeyRecord.fromJson(map.cast<String, Object?>()) : null;
      record = fetched;
      e2eeLog('record: ${fetched == null ? 'none' : 'present, ${fetched.iterations} iterations'}');
      if (fetched == null) {
        // Encryption was turned off on the server: the saved key has nothing left
        // to decrypt and must not survive into a later re-enable.
        await forget();
        return null;
      }
      await _checkSavedKeyAgainst(fetched);
      await _storage.write(key: _recordSlot, value: jsonEncode(fetched.toJson()));
      return fetched;
    } on ApiException catch (e) {
      if (e.status == 404) {
        e2eeLog('record: 404, not encrypted');
        record = null;
        await forget();
        return null;
      }
      e2eeLog('record FAILED: $e');
      rethrow;
    }
  }

  /// Called at start-up, before any sync: what this device knows without a network.
  ///
  /// The account key is restored from the platform keystore after the first
  /// successful unlock, so a normal restart does not ask for the passphrase again.
  /// The key record is stored beside it; a record belonging to a different account
  /// key discards the saved copy rather than trying to use it.
  Future<void> restore() async {
    final saved = await _storage.read(key: _recordSlot);
    if (saved != null) {
      try {
        record ??= k.KeyRecord.fromJson((jsonDecode(saved) as Map).cast<String, Object?>());
      } on Object {
        // a corrupt copy is worthless; the server sends the record again
      }
    }
    await _restoreSavedKey();
  }

  String _recordTag(k.KeyRecord value) => '${value.salt}|${value.wrappedByPassphrase}|${value.createdAt}';

  /// Reads the saved key entry. Supports the old raw-base64 shape as well as the
  /// JSON shape that carries the record it belongs to.
  Future<({String key, int createdAt, String tag})?> _readKeyEntry() async {
    final raw = await _storage.read(key: _keySlot);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final key = decoded['key']?.toString() ?? '';
        if (key.isEmpty) return null;
        return (
          key: key,
          createdAt: (decoded['createdAt'] as num?)?.toInt() ?? 0,
          tag: decoded['tag']?.toString() ?? '',
        );
      }
    } on Object {
      // The older build stored the key as bare base64; fall through to that.
    }
    return (key: raw, createdAt: 0, tag: '');
  }

  Future<void> _writeKeyEntry(k.KeyRecord fromServer, Uint8List key) =>
      _storage.write(
        key: _keySlot,
        value: jsonEncode({
          'key': b64url(key),
          'createdAt': fromServer.createdAt,
          'tag': _recordTag(fromServer),
        }),
      );

  bool _sameSavedAccount(int savedCreatedAt, String savedTag, k.KeyRecord current) {
    if (savedTag.isEmpty) return true; // older entry: let the key be used once
    if (savedTag == _recordTag(current)) return true;
    // A passphrase change keeps createdAt and only rewraps the same account key.
    return savedCreatedAt != 0 && savedCreatedAt == current.createdAt;
  }

  Future<void> _restoreSavedKey() async {
    final entry = await _readKeyEntry();
    if (entry == null) return;
    final current = record;
    if (current == null) {
      await _clearSavedKey();
      return;
    }
    try {
      final key = unb64url(entry.key);
      if (key.length != 32) throw const FormatException('bad key length');
      if (!_sameSavedAccount(entry.createdAt, entry.tag, current)) {
        await _clearSavedKey();
        return;
      }
      _accountKey = key;
      // Refresh an older/rewrapped entry with the current record identity.
      await _writeKeyEntry(current, key);
    } on Object {
      await _clearSavedKey();
    }
  }

  Future<void> _clearSavedKey() async {
    _accountKey = null;
    try {
      await _storage.delete(key: _keySlot);
    } on Object {
      // no platform keystore
    }
  }

  /// After the server sends a newer record, keep the saved key only when it still
  /// belongs to the same account key. A rewritten passphrase keeps `createdAt`;
  /// turning encryption off and on again creates a new one.
  Future<void> _checkSavedKeyAgainst(k.KeyRecord fetched) async {
    if (!persistToKeystore) return;
    final entry = await _readKeyEntry();
    if (entry == null) return;
    if (!_sameSavedAccount(entry.createdAt, entry.tag, fetched)) {
      await _clearSavedKey();
      return;
    }
    if (_accountKey != null) await _writeKeyEntry(fetched, _accountKey!);
  }

  Future<void> unlockWithPassphrase(k.KeyRecord fromServer, String passphrase) async {
    // 600,000 PBKDF2 rounds is seconds of pure-Dart hashing: on the UI isolate that
    // is long enough for Android to call the app dead, which is the crash after
    // "Unlock". It runs in its own isolate and only the result comes back.
    e2eeLog('unlock: deriving');
    final key = await _offUiIsolate(() => k.unlockWithPassphrase(fromServer, passphrase));
    e2eeLog('unlock: unwrapped ${key.length} bytes');
    await _adopt(fromServer, key);
  }

  Future<void> unlockWithRecoveryKey(k.KeyRecord fromServer, String text) async {
    final key = await _offUiIsolate(() => k.unlockWithRecoveryKey(fromServer, text));
    await _adopt(fromServer, key);
  }

  /// Unlocks from the biometric-keystore copy, if it still belongs to this key
  /// record. The platform prompt happens inside the read.
  Future<bool> unlockWithBiometrics() async {
    final current = record;
    if (current == null) return false;
    final key = await BiometricUnlock.instance.read(current);
    if (key == null) return false;
    await _adopt(current, key);
    return true;
  }

  Future<Uint8List> _offUiIsolate(Uint8List Function() work) async {
    try {
      return await Isolate.run(work);
    } on Object {
      // A platform without isolates (or a send that cannot be copied): derive here.
      return work();
    }
  }

  Future<void> _adopt(k.KeyRecord fromServer, Uint8List key) async {
    record = fromServer;
    _accountKey = key;
    _sealing = true;
    if (!persistToKeystore) return;
    // Keep the account key across restarts. The old raw-key slot is rewritten in
    // the tagged JSON shape, and the retired E2EE biometric copy is removed: app
    // lock is now the only biometric surface.
    await _writeKeyEntry(fromServer, key);
    await _storage.write(key: _recordSlot, value: jsonEncode(fromServer.toJson()));
    await BiometricUnlock.instance.disable();
  }

  /// Test seam: adopt a key without the keystore, for the replica tests.
  void adoptKeyForTest(Uint8List key) => _accountKey = key;

  /// Test seam: clear all in-memory key state without touching the keystore.
  void resetForTest() {
    _accountKey = null;
    record = null;
    _sealing = true;
  }

  /// Forgets the key but keeps the record, so the next unlock works offline.
  Future<void> lock() async {
    await _clearSavedKey();
  }

  /// Signing out and turning encryption off must leave nothing behind.
  Future<void> forget() async {
    _accountKey = null;
    record = null;
    _sealing = true;
    await BiometricUnlock.instance.disable();
    if (!persistToKeystore) return;
    try {
      await _storage.delete(key: _keySlot);
      await _storage.delete(key: _recordSlot);
    } on Object {
      // A platform without the keystore still forgets the in-memory key.
    }
  }

  /// Stores the record on the server (PUT); the recovery key is shown by the UI.
  Future<void> putRecord(ApiClient client, k.KeyRecord toStore) async {
    final json = await client.put('/api/v1/encryption/keys', body: toStore.toJson());
    final map = json is Map ? json['keys'] : null;
    record = map is Map ? k.KeyRecord.fromJson(map.cast<String, Object?>()) : toStore;
  }

  /// Keeps a key generated on this device. Enabling stores the record first, so
  /// a failure leaves the server consistent and the UI can retry.
  Future<void> adoptRecord(k.KeyRecord stored, Uint8List accountKey) async {
    _sealing = true;
    await _adopt(stored, accountKey);
  }

  /// Disabling: stop sealing outgoing values while the key is still held for
  /// the decrypt pass.
  void setSealing(bool value) => _sealing = value;

  // ---- the value path -----------------------------------------------------

  /// Encrypts one outgoing value, or returns it unchanged when the field is
  /// plaintext by design. Empty and null values are never encrypted.
  Object? seal(String entity, String entityId, String field, Object? value, {bool personal = true}) {
    final key = _accountKey;
    if (key == null || record == null || !_sealing || !personal || !isContentField(entity, field)) return value;
    if (value is! String || value.isEmpty || isEnvelope(value)) return value;
    return encryptValue(key: key, entity: entity, entityId: entityId, field: field, plaintext: value);
  }

  /// Decrypts an incoming value. A value that fails its binding becomes
  /// "[Cannot decrypt]" and the operation is still applied, so the device
  /// converges instead of looping.
  Object? open(String entity, String entityId, String field, Object? value) {
    final key = _accountKey;
    if (key == null || value is! String || !isEnvelope(value)) return value;
    try {
      return decryptValue(key: key, entity: entity, entityId: entityId, field: field, value: value);
    } on E2eeError {
      return '[Cannot decrypt]';
    }
  }

  /// Decrypts the content already stored on this device. A replica that synced
  /// before this device was unlocked holds ciphertext, and the pull path only
  /// decrypts new operations, so without this the lists keep showing `enc:v1:`.
  ///
  /// Only the local `fields` rows change: no operation is queued, because the
  /// server's copy is already the ciphertext and must stay that way.
  Future<int> openLocalReplica(OtdaDb db) async {
    final key = _accountKey;
    if (key == null) return 0;
    var opened = 0;
    var total = 0;
    final rows = await db.allFields();
    progress.value = 0;
    for (var index = 0; index < rows.length; index++) {
      if (index % 25 == 0) progress.value = rows.isEmpty ? 1 : index / rows.length;
      final row = rows[index];
      final entity = row['entity']?.toString() ?? '';
      final entityId = row['entity_id']?.toString() ?? '';
      final field = row['field']?.toString() ?? '';
      if (!isContentField(entity, field)) continue;
      final raw = row['value']?.toString() ?? '';
      Object? value;
      try {
        value = jsonDecode(raw);
      } on Object {
        continue;
      }
      if (value is! String || !isEnvelope(value)) continue;
      total++;
      try {
        final plain = decryptValue(key: key, entity: entity, entityId: entityId, field: field, value: value);
        await db.setLocalValue(entity, entityId, field, plain);
        opened++;
      } on E2eeError {
        // "[Cannot decrypt]" is a display problem, not a reason to stop the rest.
        continue;
      }
    }
    progress.value = null;
    e2eeLog('local replica: opened $opened of $total ciphertext field(s) in ${rows.length} rows');
    return opened;
  }

  Map<String, dynamic> sealOp(Map<String, dynamic> op) {
    if (!enabled) return op;
    final value = seal(op['entity'].toString(), op['entityId'].toString(), op['field'].toString(), op['value']);
    if (identical(value, op['value'])) return op;
    return {...op, 'value': value};
  }

  Map<String, dynamic> openOp(Map<String, dynamic> op) {
    if (!enabled) return op;
    final value = open(op['entity'].toString(), op['entityId'].toString(), op['field'].toString(), op['value']);
    if (identical(value, op['value'])) return op;
    return {...op, 'value': value};
  }
}
