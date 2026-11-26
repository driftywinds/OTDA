import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../security/app_lock.dart';

/// Replaces the signed-in shell with a lock screen while [AppLock] is enabled and
/// locked. It never touches encryption: the vault may still be syncing underneath.
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppLock.instance,
      builder: (context, _) {
        if (!AppLock.instance.locked) return child;
        return AppLockScreen(state: state);
      },
    );
  }
}

class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  bool _busy = false;
  String? _error;
  bool _autoTried = false;

  @override
  void initState() {
    super.initState();
    // Let the lock screen paint before the system prompt covers it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (mounted && !_autoTried) _unlock(auto: true);
      });
    });
  }

  Future<void> _unlock({bool auto = false}) async {
    if (_busy) return;
    _autoTried = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AppLock.instance.authenticate(reason: 'Unlock OTDA to see your tasks');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.ok || auto ? null : result.error;
    });
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out instead?'),
        content: const Text('You can sign back in later. Your tasks stay on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.state.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.lock_rounded, size: 36, color: scheme.primary),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'OTDA is locked',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Unlock with your fingerprint, face or device PIN to see your tasks.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _unlock(),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lock_open_rounded, size: 19),
                      label: Text(_busy ? 'Waiting…' : 'Unlock'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _signOut,
                    child: const Text('Sign out instead'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
