import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../data/repo.dart';
import 'admin_view.dart';

/// The account's settings: the synced preferences that follow the person to every
/// device, plus who they are signed in as and how.
///
/// Preferences live in the operation log under `user_prefs`/`me`, so changing one
/// here works offline and reaches the other devices on the next exchange. The
/// value `system` means "follow the device", which is what an unset field does.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, Object?> _prefs = const {};
  bool _loading = true;

  Repo? get _repo => widget.state.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await _repo?.userPrefs() ?? const <String, Object?>{};
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _loading = false;
    });
  }

  String _value(String field, String fallback) {
    final value = _prefs[field]?.toString() ?? '';
    return value.isEmpty ? fallback : value;
  }

  Future<void> _set(String field, Object? value) async {
    await _repo?.setUserPref(field, value);
    if (mounted) setState(() => _prefs = {..._prefs, field: value});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = widget.state.account;
    final server = widget.state.server;

    final isAdmin = const {'owner', 'admin'}.contains(widget.state.account?.userRole);
    final client = widget.state.client;

    return DefaultTabController(
      length: isAdmin ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: isAdmin
              ? const TabBar(tabs: [Tab(text: 'You'), Tab(text: 'Server')])
              : null,
        ),
        body: TabBarView(
          children: [
            _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _Section(
                  title: 'Account',
                  children: [
                    _Row(label: 'Name', value: account?.displayName ?? ''),
                    _Row(label: 'Email', value: account?.userEmail ?? ''),
                    _Row(label: 'Role', value: account?.userRole ?? ''),
                    _Row(
                      label: 'Signed in with',
                      value: account?.method.name == 'token' ? 'API token' : 'Password (session)',
                    ),
                    _Row(label: 'Server', value: Uri.parse(account?.serverUrl ?? '').host),
                    _Row(label: 'Server version', value: server?.version ?? ''),
                  ],
                ),
                _Section(
                  title: 'Dates and times',
                  children: [
                    _ChoiceRow(
                      label: 'Week starts on',
                      value: _value('week_start', 'system'),
                      options: const {
                        'system': 'Device',
                        'mon': 'Monday',
                        'sun': 'Sunday',
                        'sat': 'Saturday',
                      },
                      onChanged: (value) => _set('week_start', value),
                    ),
                    _ChoiceRow(
                      label: 'Date format',
                      value: _value('date_format', 'system'),
                      options: const {
                        'system': 'Device',
                        'day-month': 'Day first',
                        'month-day': 'Month first',
                        'iso': 'ISO (2026-11-18)',
                      },
                      onChanged: (value) => _set('date_format', value),
                    ),
                    _ChoiceRow(
                      label: 'Time format',
                      value: _value('time_format', 'system'),
                      options: const {
                        'system': 'Device',
                        '12h': '12-hour',
                        '24h': '24-hour',
                      },
                      onChanged: (value) => _set('time_format', value),
                    ),
                  ],
                ),
                _Section(
                  title: 'Lists',
                  children: [
                    _ChoiceRow(
                      label: 'Row layout',
                      value: _value('row_layout', 'line'),
                      options: const {
                        'line': 'One line',
                        'detailed': 'Detailed',
                      },
                      onChanged: (value) => _set('row_layout', value),
                    ),
                  ],
                ),
                _Section(
                  title: 'This device',
                  children: [
                    _Row(label: 'Sync', value: widget.state.syncError ?? 'Connected'),
                    _Row(
                      label: 'Waiting to send',
                      value: widget.state.pending == 0 ? 'Nothing' : '${widget.state.pending} change(s)',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'These preferences are stored on your server with your tasks and reach your other '
                  'devices on the next sync. "Device" means follow this phone.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () async {
                    await widget.state.signOut();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: const Text('Sign out'),
                ),
              ],
            ),
            if (isAdmin)
              client == null
                  ? const Center(child: Text('Not signed in.'))
                  : AdminView(state: widget.state),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A row whose value is picked from a short list.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in options.entries)
                  ListTile(
                    title: Text(entry.value),
                    trailing: entry.key == value
                        ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(entry.key),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
        if (chosen != null) onChanged(chosen);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Text(
              options[value] ?? value,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
