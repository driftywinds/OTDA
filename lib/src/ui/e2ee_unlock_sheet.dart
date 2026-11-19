import 'package:material_ui/material_ui.dart';

import '../e2ee/crypto.dart';
import '../e2ee/keys.dart' as keys;
import '../e2ee/session.dart';

/// Asks for the passphrase (or the recovery key) the first time this device meets
/// an encrypted account, and after "Lock this device".
///
/// Returns true when the device is unlocked. Accounts without a key record never see
/// this sheet: [E2eeSession.enabled] is false and nothing asks.
Future<bool> showE2eeUnlockSheet(BuildContext context, {bool canPostpone = true}) async {
  final session = E2eeSession.instance;
  final record = session.record;
  if (record == null) return true;

  final unlocked = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: canPostpone,
    enableDrag: canPostpone,
    showDragHandle: true,
    builder: (_) => _UnlockSheet(record: record, canPostpone: canPostpone),
  );
  return unlocked ?? false;
}

class _UnlockSheet extends StatefulWidget {
  const _UnlockSheet({required this.record, required this.canPostpone});

  final keys.KeyRecord record;
  final bool canPostpone;

  @override
  State<_UnlockSheet> createState() => _UnlockSheetState();
}

class _UnlockSheetState extends State<_UnlockSheet> {
  final _secret = TextEditingController();
  bool _recovery = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final secret = _secret.text.trim();
    if (secret.isEmpty) {
      setState(() => _error = _recovery ? 'Enter your recovery key' : 'Enter your passphrase');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_recovery) {
        await E2eeSession.instance.unlockWithRecoveryKey(widget.record, secret);
      } else {
        await E2eeSession.instance.unlockWithPassphrase(widget.record, secret);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on E2eeError catch (e) {
      setState(() => _error = e.message);
    } on Object {
      setState(() => _error = 'Could not unlock with that ${_recovery ? 'recovery key' : 'passphrase'}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The keyboard shrinks the sheet, and the fixed copy below it used to overflow by
    // 25 px (the yellow bar). Scrolling the content outranks clipping it: on a short
    // screen the "Not now" button would otherwise be unreachable with the keyboard up.
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text('This account is encrypted', style: theme.textTheme.titleLarge),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Your tasks are end-to-end encrypted on the server. Enter the passphrase to '
            'unlock them on this device; it never leaves the phone.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _secret,
            autofocus: true,
            obscureText: !_recovery,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: _recovery ? 'Recovery key' : 'Passphrase',
              hintText: _recovery ? 'XXXX-XXXX-…' : 'at least 12 characters',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_recovery) ...[
            const SizedBox(height: 6),
            Text(
              'The 56-character key you saved when encryption was turned on.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _busy ? null : () => setState(() {
                    _recovery = !_recovery;
                    _error = null;
                  }),
                  child: Text(_recovery ? 'Use the passphrase' : 'Forgot it? Use the recovery key'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Unlock'),
          ),
          if (widget.canPostpone) ...[
            const SizedBox(height: 4),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Locked means nothing syncs: no task leaves or reaches this device until you unlock.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
