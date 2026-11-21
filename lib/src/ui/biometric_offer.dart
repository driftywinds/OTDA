import 'package:material_ui/material_ui.dart';

import '../e2ee/biometric.dart';
import '../e2ee/session.dart';

/// After a passphrase unlock, asks once whether to keep the account key behind
/// the phone's fingerprint/face. Declining changes nothing.
Future<void> offerBiometricEnrollment(BuildContext context) async {
  final session = E2eeSession.instance;
  final record = session.record;
  final key = session.accountKey;
  if (record == null || key == null) return;
  if (!BiometricUnlock.instance.supported) return;
  if (await BiometricUnlock.instance.enrolled(record)) return;
  if (!context.mounted) return;
  final accept = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Unlock with fingerprint or face?'),
      content: const Text(
        'OTDA can keep this account’s key behind the phone’s biometric lock, so the next unlock does '
        'not need the passphrase. The passphrase still works, and signing out or turning encryption '
        'off removes the copy.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Enable')),
      ],
    ),
  );
  if (accept != true) return;
  try {
    await BiometricUnlock.instance.enable(key, record);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fingerprint/face unlock is on.')),
      );
    }
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This phone did not accept the biometric key. The passphrase still works.')),
      );
    }
  }
}
