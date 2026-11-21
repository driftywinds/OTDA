import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../data/sync_engine.dart';
import 'e2ee_unlock_sheet.dart';
import 'widgets.dart';

/// The first copy of the account, before the task list exists.
///
/// The shell shows this instead of the home screen until [AppState.isReady].
/// It is not a cosmetic splash: a replica that has only pulled part of the log
/// looks like lost data, so nothing task-shaped is reachable until the pull has
/// reached the server's head and every queued write has been accepted.
class SyncGateScreen extends StatefulWidget {
  const SyncGateScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SyncGateScreen> createState() => _SyncGateScreenState();
}

class _SyncGateScreenState extends State<SyncGateScreen> {
  Timer? _ticker;
  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    // The elapsed line is the only thing that changes without the state telling
    // us, so one cheap timer is enough.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() => _unlocking = true);
    try {
      final unlocked = await showE2eeUnlockSheet(context);
      if (unlocked) await widget.state.afterUnlock();
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final gate = state.gate;
    final progress = state.gateProgress;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.center,
                    child: BrandMark(size: 76),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    switch (gate) {
                      SyncGate.failed => 'The first sync did not finish',
                      SyncGate.locked => 'This account is encrypted',
                      _ => 'Getting your tasks ready',
                    },
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    switch (gate) {
                      SyncGate.failed => state.gateError ?? 'The server could not be reached. Nothing was lost.',
                      SyncGate.locked => 'Enter your passphrase once. The key never leaves this device.',
                      _ =>
                        'Your phone is copying the account from ${Uri.parse(state.account?.serverUrl ?? '').host}. '
                            'The lists open when the copy is complete.',
                    },
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (gate == SyncGate.syncing) ...[
                    _ProgressBlock(
                      progress: progress,
                      elapsed: _elapsed(state),
                    ),
                  ] else if (gate == SyncGate.locked) ...[
                    FilledButton.icon(
                      onPressed: _unlocking ? null : _unlock,
                      icon: const Icon(Icons.lock_open_rounded, size: 18),
                      label: Text(_unlocking ? 'Unlocking…' : 'Unlock'),
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: () => state.retryGate(),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try again'),
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: () async {
                      await state.signOut();
                    },
                    child: const Text('Sign out'),
                  ),
                  if (gate == SyncGate.syncing) ...[
                    const SizedBox(height: 8),
                    Text(
                      'It is safe to close the app: the copy continues where it stopped.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _elapsed(AppState state) {
    final started = state.gateStarted;
    if (started == null) return '';
    final seconds = DateTime.now().difference(started).inSeconds;
    if (seconds < 2) return 'Starting…';
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }
}

class _ProgressBlock extends StatelessWidget {
  const _ProgressBlock({required this.progress, required this.elapsed});

  final SyncProgress? progress;
  final String elapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = progress?.fraction;
    final count = progress == null
        ? 'Reading the log…'
        : progress!.total == null
        ? '${progress!.pulled} change${progress!.pulled == 1 ? '' : 's'}'
        : '${progress!.done} of ${progress!.total} changes';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 10,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(count, style: theme.textTheme.bodySmall),
            Text(
              elapsed,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
