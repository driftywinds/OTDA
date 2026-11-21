import 'dart:convert';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../data/db.dart';
import '../data/repo.dart';
import '../data/sync_engine.dart';
import 'attachments.dart';
import 'crypto.dart';
import 'fields.dart';
import 'keys.dart';
import 'scope.dart';
import 'session.dart';

/// The two directions of the content re-write.
enum E2eeMigrationMode { encrypt, decrypt }

class E2eeMigrationProgress {
  const E2eeMigrationProgress(this.done, this.total, this.mode);
  final int done;
  final int total;
  final E2eeMigrationMode mode;

  double? get fraction => total == 0 ? 1 : (done / total).clamp(0.0, 1.0);
  bool get finished => done >= total;
}

/// Enabling, the resumable content re-write, and disabling.
///
/// The order is the web client's: the key record is stored before anything is
/// encrypted, and deleted before anything is decrypted. A re-write interrupted by
/// a kill resumes by scanning for fields that are still in the wrong form, so no
/// progress cursor can go stale.
class E2eeLifecycle {
  E2eeLifecycle({
    required this.repo,
    required this.client,
    required this.engine,
    this.attachments,
    E2eeSession? session,
  }) : session = session ?? E2eeSession.instance;

  final Repo repo;
  final ApiClient client;
  final SyncEngine engine;
  final AttachmentService? attachments;
  final E2eeSession session;

  OtdaDb get db => repo.db;

  static const migrationKey = 'e2ee.migration';

  /// Step one: derive and wrap locally. Nothing leaves the device yet.
  NewKeyRecord prepare(String passphrase) => createKeyRecord(passphrase);

  /// Step two: store the record, keep the key, and re-write every personal
  /// content field as ciphertext. Returns once the outbox has drained; a network
  /// failure leaves the job recorded and resumable.
  Future<void> enable(
    NewKeyRecord prepared, {
    void Function(E2eeMigrationProgress)? onProgress,
  }) async {
    if (attachments == null) {
      await _guardFiles(encrypting: true);
    }
    await session.putRecord(client, prepared.record);
    final stored = session.record;
    if (stored == null) {
      throw const ApiException(500, 'encryption_failed', 'the server did not return the key record');
    }
    await session.adoptRecord(stored, prepared.accountKey);
    await db.setMeta(migrationKey, jsonEncode({'mode': 'encrypt'}));
    try {
      await attachments?.migrate(encrypt: true);
      await migrate(mode: E2eeMigrationMode.encrypt, onProgress: onProgress);
    } on Object {
      // The local kit is consistent; the remaining outbox and plaintext fields
      // are picked up by the next run. Do not hide that encryption is now on.
      rethrow;
    }
  }

  /// True while a re-write is recorded as unfinished.
  Future<E2eeMigrationMode?> pendingMigration() async {
    final raw = await db.meta(migrationKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final mode = (jsonDecode(raw) as Map)['mode']?.toString();
      return mode == 'decrypt' ? E2eeMigrationMode.decrypt : E2eeMigrationMode.encrypt;
    } on Object {
      return null;
    }
  }

  /// Rewrites every content field that is still in the wrong form. Runs in field
  /// order, pushes a batch whenever enough operations have queued, and never
  /// touches a shared project except to turn stray ciphertext back to plaintext.
  Future<void> migrate({
    required E2eeMigrationMode mode,
    void Function(E2eeMigrationProgress)? onProgress,
  }) async {
    final scope = await E2eeScope.load(db);
    final rows = await db.allFields();
    final content = [
      for (final row in rows)
        if (isContentField(row['entity']?.toString() ?? '', row['field']?.toString() ?? '')) row,
    ];
    var done = 0;
    var sinceDrain = 0;
    onProgress?.call(E2eeMigrationProgress(0, content.length, mode));

    for (final row in content) {
      final entity = row['entity']?.toString() ?? '';
      final id = row['entity_id']?.toString() ?? '';
      final field = row['field']?.toString() ?? '';
      Object? value;
      try {
        value = jsonDecode(row['value']?.toString() ?? 'null');
      } on FormatException {
        value = null;
      }
      final personal = await scope.personal(entity, id);
      Object? wire;
      Object? local = value;
      var updateLocal = false;
      var needsWrite = false;
      if (mode == E2eeMigrationMode.encrypt) {
        if (!personal) {
          // Shared scope must be plaintext. Turn old ciphertext back if a client
          // wrote it there before this rule.
          if (value is String && isEnvelope(value)) {
            wire = session.open(entity, id, field, value);
            local = wire;
            updateLocal = true;
            needsWrite = true;
          }
        } else if (value is String && value.isNotEmpty && !isEnvelope(value)) {
          wire = session.seal(entity, id, field, value, personal: true);
          // The replica keeps the plaintext; only the outbox carries ciphertext.
          needsWrite = true;
        }
      } else if (!personal) {
        if (value is String && isEnvelope(value)) {
          wire = session.open(entity, id, field, value);
          local = wire;
          updateLocal = true;
          needsWrite = true;
        }
      } else if (value is String && value.isNotEmpty && value != '[Cannot decrypt]') {
        // The replica already shows plaintext, but the server may still hold
        // ciphertext: every personal content field gets a plaintext overwrite.
        wire = value;
        needsWrite = true;
      }

      if (needsWrite && wire != null) {
        await repo.queueField(entity, id, field, wire, localValue: local, updateLocal: updateLocal);
        sinceDrain++;
      }
      done++;
      if (sinceDrain >= 2000) {
        await _drain();
        sinceDrain = 0;
      }
      if (done % 50 == 0) onProgress?.call(E2eeMigrationProgress(done, content.length, mode));
    }
    await _drain();
    await db.deleteMeta(migrationKey);
    onProgress?.call(E2eeMigrationProgress(content.length, content.length, mode));
  }

  Future<void> _drain() async {
    var attempts = 0;
    while (await db.outboxCount() > 0 && attempts < 200) {
      await engine.exchange();
      attempts++;
    }
  }

  /// File bytes are not re-uploaded by this build yet. Refuse the lifecycle
  /// rather than leave a file in the wrong form: enabling would keep an existing
  /// file plaintext on an encrypted account, disabling would leave it
  /// ciphertext with no key.
  Future<void> _guardFiles({required bool encrypting}) async {
    final files = [
      for (final attachment in await repo.allAttachments())
        if (!attachment.isLink && (encrypting ? !attachment.encrypted : attachment.encrypted)) attachment,
    ];
    if (files.isEmpty) return;
    throw AttachmentError(
      'files_pending',
      'This account has ${files.length} file(s) in the wrong form. File re-upload is not implemented in '
          'this build yet; remove them or change encryption in the web app first.',
    );
  }

  /// Disabling: delete the record first so no device keeps encrypting, keep the
  /// key, rewrite every field as plaintext, then forget the key.
  Future<void> disable({void Function(E2eeMigrationProgress)? onProgress}) async {
    if (!session.unlocked) {
      throw const ApiException(409, 'locked', 'unlock this device before turning encryption off');
    }
    if (attachments == null) {
      await _guardFiles(encrypting: false);
    } else {
      // The roadmap's order: decrypt and re-upload every file first, while the key
      // still exists, then delete the record.
      await attachments!.migrate(encrypt: false);
      await _drain();
    }
    try {
      await client.delete('/api/v1/encryption/keys');
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
    }
    session.setSealing(false);
    await db.setMeta(migrationKey, jsonEncode({'mode': 'decrypt'}));
    await migrate(mode: E2eeMigrationMode.decrypt, onProgress: onProgress);
    await session.forget();
  }

  /// Removes superseded content operations after encryption is on, so old
  /// plaintext cannot be read from the operation history.
  Future<int> purgeHistory() async {
    final json = await client.post('/api/v1/encryption/purge-history') as Map<String, dynamic>;
    return (json['purged'] as num?)?.toInt() ?? 0;
  }

  /// For a device that kept the key but has no record (a disable interrupted
  /// after the server delete): finish the decrypt pass without another DELETE.
  Future<void> finishDisable({void Function(E2eeMigrationProgress)? onProgress}) async {
    session.setSealing(false);
    await migrate(mode: E2eeMigrationMode.decrypt, onProgress: onProgress);
    await session.forget();
  }
}
