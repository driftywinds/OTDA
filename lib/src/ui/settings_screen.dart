import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';
import '../data/repo.dart';
import 'admin_view.dart';
import 'settings_rows.dart';
import 'theme.dart';
import 'widgets.dart';

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
          // Bigger than the tab labels below it, which it read as smaller than.
          title: Text(
            'Settings',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Row(
                        children: [
                          AccountAvatar(state: widget.state, size: 44),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(account?.displayName ?? '', style: theme.textTheme.titleMedium),
                                Text(
                                  account?.userEmail ?? '',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SettingsRow(label: 'Email', value: account?.userEmail ?? ''),
                    SettingsRow(label: 'Role', value: account?.userRole ?? ''),
                    SettingsRow(
                      label: 'Signed in with',
                      value: account?.method.name == 'token' ? 'API token' : 'Password (session)',
                    ),
                    SettingsRow(label: 'Server', value: Uri.parse(account?.serverUrl ?? '').host),
                    SettingsRow(label: 'Server version', value: server?.version ?? ''),
                  ],
                ),
                _Section(
                  title: 'Dates and times',
                  children: [
                    SettingsChoiceRow(
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
                    SettingsChoiceRow(
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
                    SettingsChoiceRow(
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
                    SettingsChoiceRow(
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
                    SettingsRow(label: 'Sync', value: widget.state.syncError ?? 'Connected'),
                    SettingsRow(
                      label: 'Waiting to send',
                      value: widget.state.pending == 0 ? 'Nothing' : '${widget.state.pending} change(s)',
                    ),
                  ],
                ),
                _Section(
                  title: 'Appearance',
                  children: [
                    SettingsChoiceRow(
                      label: 'Theme',
                      value: widget.state.themeChoice,
                      options: const {
                        'system': 'System',
                        'light': 'Light',
                        'dark': 'Dark',
                        'amoled': 'AMOLED black',
                      },
                      onChanged: (value) => widget.state.setThemeChoice(value),
                    ),
                    SettingsChoiceRow(
                      label: 'Font',
                      value: widget.state.useAllo ? 'allo' : 'system',
                      options: const {
                        'system': 'System',
                        'allo': 'Allo',
                      },
                      onChanged: (value) => widget.state.setUseAllo(value == 'allo'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'These preferences are stored on your server with your tasks and reach your other '
                  'devices on the next sync. "Device" means follow this phone.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                _Section(
                  title: 'About',
                  children: [const _AboutCard()],
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
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: theme.colorScheme.softShadow,
            ),
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who this app is, with the logo and the build actually installed.
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13)),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        );

    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final version = info == null ? '…' : '${info.version} (${info.buildNumber})';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // The logo's white tray needs a dark tile to sit on, whatever
                  // theme is chosen.
                  Container(
                    width: 56,
                    height: 56,
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('OTDA', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        Text(
                          'A client for OpenTodo servers',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              row('Version', version),
              row('Package', info?.packageName ?? 'com.dw.otda'),
              const Divider(height: 20),
              InkWell(
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'OTDA',
                  applicationVersion: info == null ? null : '${info.version} (${info.buildNumber})',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Open source licences',
                          style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
