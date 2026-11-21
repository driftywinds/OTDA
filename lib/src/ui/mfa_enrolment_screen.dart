import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../auth/mfa_service.dart';
import 'reauth.dart';
import 'widgets.dart';

/// The server owner requires a second factor and this account has none: the
/// only route the server allows is enrolment, so the shell shows this instead
/// of the task list.
class MfaEnrolmentScreen extends StatefulWidget {
  const MfaEnrolmentScreen({super.key, required this.state});

  final AppState state;

  @override
  State<MfaEnrolmentScreen> createState() => _MfaEnrolmentScreenState();
}

class _MfaEnrolmentScreenState extends State<MfaEnrolmentScreen> {
  static const _service = MfaService();

  TotpEnrollment? _enrolment;
  List<String>? _codes;
  final _code = TextEditingController();
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _enrol();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _enrol() async {
    final client = widget.state.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      TotpEnrollment? enrolment;
      try {
        enrolment = await _service.enroll(client);
      } on ApiException catch (e) {
        if (!e.needsReauth) rethrow;
        if (!mounted) return;
        if (!await askReauth(context, widget.state, enrolled: false)) {
          setState(
            () => _error =
                'Confirm your password to set up two-factor authentication.',
          );
          return;
        }
        enrolment = await _service.enroll(client);
      }
      setState(() => _enrolment = enrolment);
    } on ApiException catch (e) {
      setState(() => _error = _explain(e));
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final client = widget.state.client;
    final enrolment = _enrolment;
    if (client == null || enrolment == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final confirmation = await _service.confirm(client, _code.text);
      setState(() => _codes = confirmation.recoveryCodes);
    } on ApiException catch (e) {
      setState(() => _error = _explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _explain(ApiException e) => switch (e.code) {
    'mfa_code_invalid' =>
      'That code did not match. Check the phone\'s clock, or start again.',
    'mfa_already_enrolled' =>
      'Two-factor authentication is already on for this account.',
    'reauth_required' => 'Confirm your password to continue.',
    'rate_limited' => 'Too many attempts. Wait a minute.',
    _ => e.message,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codes = _codes;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.center,
                    child: BrandMark(size: 64),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    codes == null
                        ? 'Set up two-factor authentication'
                        : 'Save your recovery codes',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    codes == null
                        ? '${_serverHost()} requires a second factor for this account. '
                              'Add the key below to any authenticator app, then enter its six-digit code.'
                        : 'These are shown once. Store them where you keep passwords: each one '
                              'signs you in if the authenticator is lost.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_busy && _enrolment == null && codes == null)
                    const Center(child: CircularProgressIndicator())
                  else if (codes != null)
                    _CodesView(
                      codes: codes,
                      onContinue: () async {
                        await widget.state.finishMfaEnrolment();
                      },
                    )
                  else if (_enrolment != null)
                    _EnrolView(
                      enrolment: _enrolment!,
                      code: _code,
                      busy: _busy,
                      onConfirm: _confirm,
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () async {
                      await widget.state.signOut();
                    },
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _serverHost() => Uri.parse(widget.state.account?.serverUrl ?? '').host;
}

class _EnrolView extends StatelessWidget {
  const _EnrolView({
    required this.enrolment,
    required this.code,
    required this.busy,
    required this.onConfirm,
  });

  final TotpEnrollment enrolment;
  final TextEditingController code;
  final bool busy;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Key', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                SelectableText(
                  enrolment.secret,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: enrolment.secret),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Key copied')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy key'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'In your authenticator, choose "enter a setup key".',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: enrolment.uri),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Setup link copied')),
                        );
                      }
                    },
                    child: const Text('Copy setup link'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Six-digit code',
            prefixIcon: Icon(Icons.pin_outlined),
          ),
          onSubmitted: (_) => onConfirm(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : onConfirm,
          child: Text(busy ? 'Checking…' : 'Turn on'),
        ),
      ],
    );
  }
}

class _CodesView extends StatelessWidget {
  const _CodesView({required this.codes, required this.onContinue});

  final List<String> codes;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final code in codes)
                  SelectableText(
                    code,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 1.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: codes.join('\n')));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Recovery codes copied')),
              );
            }
          },
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('Copy all codes'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: onContinue,
          child: const Text('I saved them — continue'),
        ),
      ],
    );
  }
}
