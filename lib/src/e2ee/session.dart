import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../data/db.dart';
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
/// The key lives in the platform keystore, never in the database or prefs, and is
/// forgotten by "Lock this device".
class E2eeSession {
  E2eeSession._();

  static final E2eeSession instance = E2eeSession._();
  static const _storage = FlutterSecureStorage();
  static const _keySlot = 'e2ee.accountKey';
  static const _recordSlot = 'e2ee.record';

  k.KeyRecord? record;
  Uint8List? _accountKey;

  /// 0..1 while the stored ciphertext is decrypted after an unlock, null otherwise.
  final progress = ValueNotifier<double?>(null);

  bool get enabled => record != null;
  bool get unlocked => _accountKey != null;

  /// Reads the wrapped record. A 404 (or no record) means the account is not
  /// encrypted, which is the usual case.
  Future<k.KeyRecord?> fetchRecord(ApiClient client) async {
    try {
      final json = await client.get('/api/v1/encryption/keys');
      final map = json is Map ? json['keys'] : null;
      final fetched = map is Map ? k.KeyRecord.fromJson(map.cast<String, Object?>()) : null;
      record = fetched;
      e2eeLog('record: ${fetched == null ? 'none' : 'present, ${fetched.iterations} iterations'}');
      if (fetched != null) {
        await _storage.write(key: _recordSlot, value: jsonEncode(fetched.toJson()));
      }
      return fetched;
    } on ApiException catch (e) {
      if (e.status == 404) {
        e2eeLog('record: 404, not encrypted');
        record = null;
        return null;
      }
      e2eeLog('record FAILED: $e');
      rethrow;
    }
  }

  /// Called at start-up, before any sync: what this device knows without a network.
  Future<void> restore() async {
    final raw = await _storage.read(key: _keySlot);
    if (raw != null) _accountKey = unb64url(raw);
    final saved = await _storage.read(key: _recordSlot);
    if (saved != null) {
      try {
        record ??= k.KeyRecord.fromJson((jsonDecode(saved) as Map).cast<String, Object?>());
      } on Object {
        // a corrupt copy is worthless; the server sends the record again
      }
    }
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
    await _storage.write(key: _keySlot, value: b64url(key));
    await _storage.write(key: _recordSlot, value: jsonEncode(fromServer.toJson()));
  }

  /// Forgets the key but keeps the record, so the next unlock works offline.
  Future<void> lock() async {
    _accountKey = null;
    await _storage.delete(key: _keySlot);
  }

  /// Signing out and turning encryption off must leave nothing behind.
  Future<void> forget() async {
    _accountKey = null;
    record = null;
    await _storage.delete(key: _keySlot);
    await _storage.delete(key: _recordSlot);
  }

  /// Stores the record on the server (PUT); the recovery key is shown by the UI.
  Future<void> putRecord(ApiClient client, k.KeyRecord toStore) async {
    final json = await client.put('/api/v1/encryption/keys', body: toStore.toJson());
    final map = json is Map ? json['keys'] : null;
    record = map is Map ? k.KeyRecord.fromJson(map.cast<String, Object?>()) : toStore;
  }

  // ---- the value path -----------------------------------------------------

  /// Encrypts one outgoing value, or returns it unchanged when the field is
  /// plaintext by design. Empty and null values are never encrypted.
  Object? seal(String entity, String entityId, String field, Object? value) {
    final key = _accountKey;
    if (key == null || !isContentField(entity, field)) return value;
    if (value is! String || value.isEmpty) return value;
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
