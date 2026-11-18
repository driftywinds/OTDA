import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../auth/auth_service.dart';

/// Server address, then sign-in: password (primary) or an API token.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _token = TextEditingController();
  final _code = TextEditingController();

  Uri? _origin;
  ServerInfo? _info;
  bool _useToken = false;
  bool _remember = false;
  bool _busy = false;
  String? _error;
  MfaChallenge? _challenge;

  @override
  void dispose() {
    for (final c in [_server, _email, _password, _token, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      setState(() => _error = _explain(e));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _explain(ApiException e) => switch (e.code) {
        'invalid_credentials' => 'That email or password is wrong.',
        'mfa_code_invalid' => 'That code is not valid.',
        'mfa_challenge_invalid' => 'The sign-in timed out. Start again.',
        'unauthorized' => 'The server did not accept this token.',
        'insufficient_scope' => 'This token is not allowed to read the account.',
        'rate_limited' => 'Too many attempts. Wait a minute.',
        'invalid_server' || 'insecure_server' => e.message,
        'network' || 'timeout' => 'Could not reach the server. Check the address and your connection.',
        'not_found' => 'That address is not an OpenTodo server.',
        _ => e.message,
      };

  Future<void> _connect() => _run(() async {
        final origin = AuthService.parseServer(_server.text);
        final client = widget.state.newClient(origin);
        final info = await widget.state.probe(client);
        setState(() {
          _origin = origin;
          _info = info;
        });
      });

  Future<void> _signInPassword() => _run(() async {
        final client = widget.state.newClient(_origin!);
        final outcome = await widget.state.signInWithPassword(client, _email.text, _password.text);
        final challenge = outcome.challenge;
        if (challenge != null) {
          setState(() => _challenge = challenge);
        } else {
          // Let the platform's password manager offer to save the credential.
          TextInput.finishAutofillContext();
        }
      });

  Future<void> _submitCode() => _run(() async {
        final client = widget.state.newClient(_origin!);
        await widget.state.finishMfa(client, _challenge!.challenge,
            code: _code.text.trim(), remember: _remember);
        TextInput.finishAutofillContext();
      });

  Future<void> _signInToken() => _run(() async {
        final client = widget.state.newClient(_origin!);
        await widget.state.signInWithToken(client, _token.text);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _info != null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              // One group so a password manager sees the address, the email and
              // the password as one credential and offers to save it.
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('OTDA', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      connected ? 'Connected to ${_origin!.host} · v${_info!.version}' : 'Your tasks, your server.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    if (!connected) ..._serverStep() else ..._credentialStep(),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _serverStep() => [
        TextField(
          controller: _server,
          autocorrect: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autofillHints: const [AutofillHints.url],
          decoration: const InputDecoration(labelText: 'Server address', hintText: 'todo.example.com'),
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy ? const _Spinner() : const Text('Connect'),
        ),
      ];

  List<Widget> _credentialStep() {
    if (_challenge != null) {
      return [
        Text('Two-factor code', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Authenticator code or recovery code'),
          onSubmitted: (_) => _submitCode(),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _remember,
          onChanged: (v) => setState(() => _remember = v ?? false),
          title: const Text('Trust this device for 30 days'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submitCode,
          child: _busy ? const _Spinner() : const Text('Verify'),
        ),
      ];
    }

    return [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Password'), icon: Icon(Icons.password)),
          ButtonSegment(value: true, label: Text('API token'), icon: Icon(Icons.key)),
        ],
        selected: {_useToken},
        onSelectionChanged: (s) => setState(() {
          _useToken = s.first;
          _error = null;
        }),
      ),
      const SizedBox(height: 16),
      if (!_useToken) ...[
        TextField(
          controller: _email,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _signInPassword(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _signInPassword,
          child: _busy ? const _Spinner() : const Text('Sign in'),
        ),
      ] else ...[
        TextField(
          controller: _token,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'API token',
            hintText: 'ot_…',
            helperText: 'Settings → Integrations → API tokens',
          ),
          onSubmitted: (_) => _signInToken(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _signInToken,
          child: _busy ? const _Spinner() : const Text('Use token'),
        ),
      ],
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy ? null : () => setState(() {
          _info = null;
          _origin = null;
          _error = null;
        }),
        child: const Text('Use another server'),
      ),
    ];
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
