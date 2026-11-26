import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../e2ee/attachments.dart';
import '../e2ee/crypto.dart';
import '../e2ee/keys.dart';
import '../e2ee/lifecycle.dart';
import '../e2ee/session.dart';
import 'reauth.dart';
import 'settings_rows.dart';
import 'theme.dart';

/// The account's encryption: turn it on (with the one-time recovery key), finish
/// an interrupted rewrite, purge old content history, or turn it off.
class EncryptionSettingsCard extends StatefulWidget {
  const EncryptionSettingsCard({super.key, required this.state});

  final AppState state;

  @override
  State<EncryptionSettingsCard> createState() => _EncryptionSettingsCardState();
}

class _EncryptionSettingsCardState extends State<EncryptionSettingsCard> {
  bool _busy = false;
  E2eeMigrationProgress? _progress;
  String? _error;
  E2eeMigrationMode? _pending;

  E2eeSession get _session => E2eeSession.instance;

  E2eeLifecycle? get _lifecycle {
    final repo = widget.state.repo;
    final client = widget.state.client;
    final engine = widget.state.engine;
    if (repo == null || client == null || engine == null) return null;
    final author = widget.state.account?.userId ?? '';
    return E2eeLifecycle(
      repo: repo,
      client: client,
      engine: engine,
      attachments: author.isEmpty
          ? null
          : AttachmentService(repo: repo, client: client, authorId: author),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  Future<void> _loadPending() async {
    final lifecycle = _lifecycle;
    if (lifecycle == null) return;
    final pending = await lifecycle.pendingMigration();
    if (mounted) setState(() => _pending = pending);
  }

  Future<void> _enable() async {
    final lifecycle = _lifecycle;
    if (lifecycle == null) return;
    final passphrase = await _askPassphrase();
    if (passphrase == null) return;
    final NewKeyRecord prepared;
    try {
      prepared = lifecycle.prepare(passphrase);
    } on E2eeError catch (e) {
      setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    final saved = await _showRecoveryKey(prepared.recoveryKey);
    if (!saved) return;
    await _run(
      () => lifecycle.enable(prepared, onProgress: (p) => setState(() => _progress = p)),
      success: 'Encryption is on. Every personal field was rewritten as ciphertext.',
    );
    await _loadPending();
  }

  Future<void> _finishPending() async {
    final lifecycle = _lifecycle;
    final pending = _pending;
    if (lifecycle == null || pending == null) return;
    if (!_session.unlocked) {
      final unlocked = await _unlock();
      if (!unlocked) return;
    }
    await _run(
      () => pending == E2eeMigrationMode.decrypt
          ? lifecycle.finishDisable(onProgress: (p) => setState(() => _progress = p))
          : lifecycle.migrate(mode: pending, onProgress: (p) => setState(() => _progress = p)),
    );
    await _loadPending();
  }

  Future<bool> _unlock() async {
    final record = _session.record;
    if (record == null) return false;
    final passphrase = await _askUnlockPassphrase();
    if (passphrase == null) return false;
    setState(() => _busy = true);
    try {
      await _session.unlockWithPassphrase(record, passphrase);
      final repo = widget.state.repo;
      if (repo != null) await _session.openLocalReplica(repo.db);
      if (mounted) {
        setState(() {});
      }
      return true;
    } on Object catch (e) {
      if (mounted) setState(() => _error = e is E2eeError ? e.message : 'That passphrase did not unlock the account.');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    final lifecycle = _lifecycle;
    if (lifecycle == null) return;
    if (!_session.unlocked && !await _unlock()) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off end-to-end encryption?'),
        content: const Text(
          'The key record is deleted first, then every personal field is rewritten as plaintext. '
          'The server and its backups will hold your content in the clear. This needs a fresh '
          'password confirmation.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep encryption')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Turn off')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    if (!await askReauth(context, widget.state, enrolled: widget.state.mfaStatus?.enrolled ?? false)) return;
    await _run(
      () => lifecycle.disable(onProgress: (p) => setState(() => _progress = p)),
      success: 'Encryption is off. Content is plaintext and the key record was deleted.',
    );
    await _loadPending();
  }

  Future<void> _purge() async {
    final lifecycle = _lifecycle;
    if (lifecycle == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Purge old content history?'),
        content: const Text(
          'Removes superseded values of encrypted fields from the operation history, so old plaintext '
          'cannot be read there. The current value of every field stays.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Purge')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final count = await lifecycle.purgeHistory();
      _say('Purged $count superseded value(s).');
    } on ApiException catch (e) {
      _say(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    try {
      await action();
      if (success != null) _say(success);
    } on ApiException catch (e) {
      final message = switch (e.code) {
        'encryption_conflict' =>
          'Another device enabled encryption first. Unlock with its passphrase instead.',
        'reauth_required' => 'That change needs a fresh password confirmation.',
        'network' || 'timeout' => 'The rewrite is saved on this device and will resume when the server is reachable.',
        _ => e.message,
      };
      setState(() => _error = message);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _askPassphrase() => showDialog<String>(
        context: context,
        builder: (context) => const _PassphraseDialog(),
      );

  Future<String?> _askUnlockPassphrase() => showDialog<String>(
        context: context,
        builder: (context) => const _UnlockDialog(),
      );

  Future<bool> _showRecoveryKey(String key) async {
    final acknowledged = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RecoveryKeyDialog(recoveryKey: key),
    );
    return acknowledged == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = _session.enabled;
    final unlocked = _session.unlocked;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(enabled ? Icons.lock_rounded : Icons.lock_open_rounded, size: 19, color: scheme.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    enabled ? (unlocked ? 'Encryption is on and unlocked' : 'Encryption is on and locked') : 'Encryption is off',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                SettingsStatusBadge(
                  text: !enabled ? 'Off' : (unlocked ? 'Unlocked' : 'Locked'),
                  good: enabled && unlocked,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              enabled
                  ? 'Personal fields are ciphertext on the server. Shared projects stay readable to their members and are never encrypted. '
                      'The passphrase is remembered on this device after the first unlock.'
                  : 'Content fields are stored in the clear on your server. Turning encryption on rewrites them as ciphertext and shows a recovery key once.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (_pending != null) ...[
              const SizedBox(height: 8),
              Text(
                _pending == E2eeMigrationMode.encrypt
                    ? 'An encryption rewrite was interrupted. Finish it to seal the remaining fields.'
                    : 'Turning encryption off was interrupted. Finish decrypting the remaining fields.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (_progress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress!.fraction),
              const SizedBox(height: 4),
              Text(
                '${_progress!.mode == E2eeMigrationMode.encrypt ? 'Encrypting' : 'Decrypting'} '
                '${_progress!.done} of ${_progress!.total}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            if (!enabled) ...[
              if (_pending != null)
                SettingsAction(
                  icon: Icons.sync_rounded,
                  title: 'Finish turning encryption off',
                  subtitle: 'Decrypt the fields left from an interrupted rewrite',
                  onTap: _busy ? null : _finishPending,
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _enable,
                  icon: const Icon(Icons.lock_rounded, size: 18),
                  label: const Text('Turn on encryption'),
                ),
              ),
            ] else ...[
              if (!unlocked)
                SettingsAction(
                  icon: Icons.key_rounded,
                  title: 'Unlock with passphrase',
                  subtitle: 'Open the vault on this device',
                  onTap: _busy ? null : _unlock,
                ),
              if (_pending != null)
                SettingsAction(
                  icon: Icons.sync_rounded,
                  title: 'Finish the rewrite',
                  subtitle: 'Continue sealing or decrypting the remaining fields',
                  onTap: _busy ? null : _finishPending,
                ),
              Divider(height: 1, color: scheme.cardBorder),
              SettingsAction(
                icon: Icons.cleaning_services_outlined,
                title: 'Purge content history',
                subtitle: 'Delete superseded encrypted versions from the server',
                onTap: _busy ? null : _purge,
              ),
              Divider(height: 1, color: scheme.cardBorder),
              SettingsAction(
                icon: Icons.lock_open_rounded,
                title: 'Turn off encryption',
                subtitle: 'Content returns to plaintext on the server',
                destructive: true,
                onTap: _busy ? null : _disable,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _pass = TextEditingController();
  final _again = TextEditingController();
  bool _understand = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _again.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pass.text.length < 12) {
      setState(() => _error = 'Use at least 12 characters.');
      return;
    }
    if (_pass.text != _again.text) {
      setState(() => _error = 'The two passphrases do not match.');
      return;
    }
    if (!_understand) {
      setState(() => _error = 'Confirm that you understand the passphrase cannot be recovered.');
      return;
    }
    Navigator.of(context).pop(_pass.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose a passphrase'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This passphrase unwraps the account key. Nobody, including the server owner, can reset or '
              'recover it. Keep it somewhere safe; a recovery key comes next.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Passphrase (12+ characters)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _again,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Repeat the passphrase'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _understand,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'I understand that losing this passphrase and the recovery key means losing access to the data.',
                style: TextStyle(fontSize: 12),
              ),
              onChanged: (value) => setState(() => _understand = value == true),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

class _UnlockDialog extends StatefulWidget {
  const _UnlockDialog();

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _pass = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unlock encryption'),
      content: TextField(
        controller: _pass,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Passphrase'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_pass.text), child: const Text('Unlock')),
      ],
    );
  }
}

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({required this.recoveryKey});

  final String recoveryKey;

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save your recovery key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'This is the only time the recovery key is shown. Keep it apart from the passphrase. '
            'Either one alone opens the data.',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              widget.recoveryKey,
              style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.recoveryKey));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recovery key copied.')));
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy'),
          ),
          CheckboxListTile(
            value: _saved,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('I saved the recovery key.', style: TextStyle(fontSize: 13)),
            onChanged: (value) => setState(() => _saved = value == true),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: _saved ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Turn on encryption'),
        ),
      ],
    );
  }
}
