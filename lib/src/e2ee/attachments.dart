import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/repo.dart';
import 'crypto.dart';
import 'scope.dart';
import 'session.dart';

class AttachmentError implements Exception {
  const AttachmentError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class OpenedAttachment {
  const OpenedAttachment(this.bytes, this.name, this.mime);
  final Uint8List bytes;
  final String name;
  final String mime;
}

/// Files attached to tasks: create the row, keep the stored bytes on the device,
/// upload them, and download/verify/decrypt on open.
///
/// An encrypted account encrypts files only for personal tasks; a shared
/// project's files stay readable to its members. The stored envelope is what the
/// row's `size` and `sha256` describe.
class AttachmentService {
  AttachmentService({
    required this.repo,
    required this.client,
    required this.authorId,
    this.directoryOverride,
    E2eeSession? session,
  }) : session = session ?? E2eeSession.instance;

  final Repo repo;
  final ApiClient client;
  final String authorId;
  final Future<Directory> Function()? directoryOverride;
  final E2eeSession session;

  OtdaDb get db => repo.db;

  Future<Directory> _attachmentsDir() async {
    final base = await (directoryOverride ?? getApplicationSupportDirectory)();
    final dir = Directory(p.join(base.path, 'attachments'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _storedFile(String id) async => File(p.join((await _attachmentsDir()).path, '$id.bin'));

  Future<List<Attachment>> list(String taskId) => repo.attachments(taskId);

  /// Adds a file: encrypts it when the task is personal and the account is
  /// encrypted, writes the row, stores the bytes locally and uploads them.
  Future<Attachment> add({
    required String taskId,
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    final personal = await (await E2eeScope.load(db)).personal('task', taskId);
    final encrypt = session.enabled && personal;
    if (encrypt && !session.unlocked) {
      throw const AttachmentError('locked', 'Unlock encryption on this device before adding a file.');
    }
    final id = Repo.newId();
    final stored = encrypt
        ? encryptFileBytes(key: session.accountKey!, attachmentId: id, plaintext: bytes)
        : bytes;
    if (encrypt && stored.length > bytes.length) {
      // The envelope only adds 16 bytes per MiB; the check is here because the
      // server's limit applies to the stored form.
      if (stored.length - bytes.length > 1024 * 1024) {
        throw const AttachmentError('too_large', 'The encrypted file is too large.');
      }
    }
    final file = await _storedFile(id);
    await file.writeAsBytes(stored, flush: true);
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.createEntity('attachment', id, {
      'task_id': taskId,
      'comment_id': null,
      'note_id': null,
      'file_id': null,
      'name': name,
      'mime': mime,
      'size': stored.length,
      'sha256': sha256Hex(stored),
      'url': null,
      'encrypted': encrypt,
      'author_id': authorId,
      'created_at': now,
      'uploaded_at': null,
      'deleted_at': null,
    });
    try {
      await upload(id);
    } on ApiException {
      // The row and bytes stay; the next open retries.
    }
    return (await repo.attachments(taskId)).firstWhere((a) => a.id == id);
  }

  /// Sends the stored bytes. A 409 `already_uploaded` means an earlier attempt
  /// succeeded, which is the same outcome.
  Future<void> upload(String attachmentId) async {
    final attachment = (await _find(attachmentId));
    if (attachment == null) throw const AttachmentError('not_found', 'That attachment no longer exists.');
    if (attachment.isLink) return;
    final file = await _storedFile(attachment.fileKey);
    if (!await file.exists()) {
      throw const AttachmentError('missing_file', 'The file is not on this device any more.');
    }
    try {
      await client.putBytes('/api/v1/attachments/${Uri.encodeComponent(attachment.fileKey)}/content',
          await file.readAsBytes());
    } on ApiException catch (e) {
      if (e.code != 'already_uploaded') rethrow;
    }
  }

  /// Retries every attachment of a task that the server has not confirmed yet.
  Future<void> uploadPending(String taskId) async {
    for (final attachment in await list(taskId)) {
      if (!attachment.isAvailable && !attachment.isLink) {
        try {
          await upload(attachment.id);
        } on Object {
          // Keep the row; the next open tries again.
        }
      }
    }
  }

  /// Downloads the stored bytes, checks the digest, and decrypts when the row is
  /// encrypted. Nothing is returned unless every chunk passed.
  Future<OpenedAttachment> open(Attachment attachment) async {
    if (attachment.isLink) {
      throw const AttachmentError('link', 'This attachment is a link, not a file.');
    }
    if (attachment.encrypted && !session.unlocked) {
      throw const AttachmentError('locked', 'Unlock encryption to open this file.');
    }
    final stored = await client.getBytes(
      '/api/v1/attachments/${Uri.encodeComponent(attachment.fileKey)}/content',
      timeout: const Duration(minutes: 3),
    );
    if (attachment.sha256.isNotEmpty && sha256Hex(stored) != attachment.sha256) {
      throw const AttachmentError('check_failed', 'The downloaded file failed its check; nothing was opened.');
    }
    final bytes = attachment.encrypted
        ? decryptFileBytes(
            key: session.accountKey!,
            attachmentId: attachment.fileKey,
            envelope: stored,
          )
        : stored;
    return OpenedAttachment(bytes, attachment.name, attachment.mime);
  }

  /// Writes the opened bytes to a temporary file for the viewer or share sheet.
  Future<File> materialize(OpenedAttachment opened) async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'opened'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = opened.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
    final file = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}-$safe'));
    await file.writeAsBytes(opened.bytes, flush: true);
    return file;
  }

  Future<void> remove(Attachment attachment) async {
    try {
      await client.delete('/api/v1/attachments/${Uri.encodeComponent(attachment.id)}');
    } on ApiException {
      // The local tombstone still hides it; the next sync settles the server.
    }
    await repo.setField('attachment', attachment.id, 'deleted_at', DateTime.now().millisecondsSinceEpoch);
    try {
      final file = await _storedFile(attachment.fileKey);
      if (await file.exists()) await file.delete();
    } on Object {
      // The bytes may already be gone.
    }
  }

  Future<Attachment?> _find(String id) async {
    final rows = await db.entities('attachment');
    for (final row in rows) {
      if (row['id']?.toString() == id) return Attachment(row);
    }
    return null;
  }
}
