import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';

/// Confirms the password (or a second-factor code) for a step-up route.
///
/// The server's sensitive routes answer 403 `reauth_required` when the session
/// has not proved identity in the last ten minutes. Returns true when it
/// succeeded, false when the person cancelled.
Future<bool> askReauth(
  BuildContext context,
  AppState state, {
  bool enrolled = false,
}) async {
  if (state.account?.method.name == 'token') {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm your password'),
        content: const Text(
          'This change needs a recently confirmed password, and this device is signed in '
          'with an API token. Sign out and sign in with your password to change it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  final password = TextEditingController();
  final code = TextEditingController();
  final busy = ValueNotifier<bool>(false);
  final error = ValueNotifier<String?>(null);
  final useCode = ValueNotifier<bool>(enrolled);

  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => ValueListenableBuilder<bool>(
      valueListenable: busy,
      builder: (context, working, _) => AlertDialog(
        title: const Text('Confirm it is you'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (context, message, _) => message == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: useCode,
              builder: (context, byCode, _) => TextField(
                controller: byCode ? code : password,
                autofocus: true,
                obscureText: !byCode,
                keyboardType: byCode
                    ? TextInputType.number
                    : TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: byCode ? 'Authentication code' : 'Password',
                ),
                onSubmitted: (_) => _submit(
                  state,
                  context,
                  password,
                  code,
                  byCode,
                  busy,
                  error,
                ),
              ),
            ),
            if (enrolled)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: working
                      ? null
                      : () {
                          useCode.value = !useCode.value;
                          error.value = null;
                        },
                  child: Text(
                    useCode.value ? 'Use my password' : 'Use my authenticator',
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: working ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: working
                ? null
                : () => _submit(
                    state,
                    context,
                    password,
                    code,
                    useCode.value,
                    busy,
                    error,
                  ),
            child: Text(working ? 'Confirming…' : 'Confirm'),
          ),
        ],
      ),
    ),
  );
  password.dispose();
  code.dispose();
  busy.dispose();
  error.dispose();
  useCode.dispose();
  return ok ?? false;
}

Future<void> _submit(
  AppState state,
  BuildContext context,
  TextEditingController password,
  TextEditingController code,
  bool byCode,
  ValueNotifier<bool> busy,
  ValueNotifier<String?> error,
) async {
  if (busy.value) return;
  busy.value = true;
  error.value = null;
  try {
    await state.reauth(
      password: byCode ? null : password.text,
      code: byCode ? code.text.trim() : null,
    );
    if (context.mounted) Navigator.of(context).pop(true);
  } on ApiException catch (e) {
    error.value = switch (e.code) {
      'invalid_credentials' => 'That password is not right.',
      'mfa_code_invalid' => 'That code is not valid.',
      'rate_limited' => 'Too many attempts. Wait a minute.',
      _ => e.message,
    };
  } finally {
    busy.value = false;
  }
}
