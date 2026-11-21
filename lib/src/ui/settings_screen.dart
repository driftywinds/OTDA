import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../reminders/debug_log.dart';
import '../reminders/service.dart';
import '../system_bridge.dart';
import '../widget/widget_settings.dart';

import '../app_state.dart';
import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../auth/mfa_service.dart';
import '../data/repo.dart';
import 'admin_view.dart';
import 'reauth.dart';
import 'settings_rows.dart';
import '../e2ee/session.dart';
import 'e2ee_unlock_sheet.dart';
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
                  title: 'Two-factor authentication',
                  children: [_TwoFactorCard(state: widget.state)],
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
                _Section(title: 'End-to-end encryption', children: [_EncryptionCard(state: widget.state)]),
                _Section(title: 'Notifications', children: [_NotificationsCard(state: widget.state)]),
                const _Section(title: 'Home screen widget', children: [_WidgetCard()]),
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
                  const BrandMark(size: 64),
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


/// Reminders, made visible: whether they may fire, whether they are armed, and ways
/// to prove it from a plain notification up to a real task that fires while the
/// phone is locked.
class _NotificationsCard extends StatefulWidget {
  const _NotificationsCard({required this.state});

  final AppState state;

  @override
  State<_NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<_NotificationsCard> with WidgetsBindingObserver {
  bool? _allowed;
  bool? _exact;
  bool? _battery;
  bool _enabled = true;
  bool _alarmClock = true;
  String _time = '09:00';
  String _maker = '';
  int _armed = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from a system settings screen: show what changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(rearm: true);
  }

  Future<void> _refresh({bool rearm = false}) async {
    final service = ReminderService.instance;
    if (rearm) await widget.state.afterDataChanged();
    final allowed = await service.notificationsEnabled();
    final exact = await service.exactAlarmsAllowed();
    final armed = await service.armedCount();
    final battery = await SystemBridge.ignoringBatteryOptimizations();
    final enabled = await service.remindersEnabled();
    final alarmClock = await service.alarmClockMode();
    final time = await service.reminderTime();
    final maker = await SystemBridge.manufacturer();
    if (!mounted) return;
    setState(() {
      _allowed = allowed;
      _exact = exact;
      _battery = battery;
      _enabled = enabled;
      _alarmClock = alarmClock;
      _time = time;
      _maker = maker;
      _armed = armed;
    });
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 6)));
  }

  Future<void> _allow() async {
    final granted = await ReminderService.instance.requestPermission();
    if (!granted) {
      // Refused (or refused before): Android will not show the dialog again, so the
      // only way left is the system settings page.
      _say('Turn on notifications for OTDA in the screen that just opened.');
      await SystemBridge.openNotificationSettings();
    }
    await _refresh(rearm: true);
  }

  Future<void> _pickTime() async {
    final parts = _time.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 9,
        minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      ),
    );
    if (picked == null) return;
    final value = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    await ReminderService.instance.setReminderTime(value);
    await widget.state.afterDataChanged();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 13);
    final service = ReminderService.instance;

    Widget status(String label, String value, {bool good = true, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(child: Text(label, style: style)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style?.copyWith(
                      color: good ? scheme.onSurfaceVariant : scheme.error,
                      fontWeight: good ? null : FontWeight.w600,
                    ),
                  ),
                ),
                // The rows are still tappable, but the trailing arrow on every one of
                // them read as "next" and made the card look like a menu of five
                // steps. The width is kept so values stay aligned with the other cards.
                const SizedBox(width: 24),
              ],
            ),
          ),
        );

    Widget action(IconData icon, String title, String subtitle, Future<void> Function() run) => ListTile(
          dense: true,
          leading: Icon(icon, size: 18, color: scheme.primary),
          title: Text(title, style: style),
          subtitle: Text(subtitle),
          onTap: run,
        );

    const divider = Divider(height: 1, indent: 16, endIndent: 16);
    final repo = widget.state.repo;
    final next = service.lastPlan.take(5).toList();
    final xiaomiFamily = _maker.contains('xiaomi') || _maker.contains('redmi') || _maker.contains('poco');

    return Column(
      children: [
        SwitchListTile(
          dense: true,
          value: _enabled,
          title: Text('Remind me about tasks', style: style),
          subtitle: const Text('A notification at each task\'s time'),
          onChanged: (value) async {
            setState(() => _enabled = value);
            await service.setRemindersEnabled(value);
            await widget.state.afterDataChanged();
            await _refresh();
          },
        ),
        divider,
        SwitchListTile(
          dense: true,
          value: _alarmClock,
          title: Text('Extra reliable (alarm-clock mode)', style: style),
          subtitle: const Text('Fires on time even when the phone is strict about battery. Shows a small alarm icon'),
          onChanged: (value) async {
            setState(() => _alarmClock = value);
            await service.setAlarmClockMode(value);
            await widget.state.afterDataChanged();
            await _refresh();
          },
        ),
        divider,
        status('Time for tasks without one', _time, onTap: _pickTime),
        divider,
        status(
          'Notifications',
          _allowed == null ? '…' : (_allowed! ? 'Allowed' : 'Blocked, tap to allow'),
          good: _allowed ?? true,
          onTap: _allowed == true ? SystemBridge.openNotificationSettings : _allow,
        ),
        divider,
        status(
          'Exact alarms',
          _exact == null ? '…' : (_exact! ? 'Allowed' : 'Off, reminders may be late'),
          good: _exact ?? true,
          onTap: _exact == true ? null : SystemBridge.openExactAlarmSettings,
        ),
        divider,
        status(
          'Battery',
          _battery == null ? '…' : (_battery! ? 'Unrestricted' : 'Optimised, may delay reminders'),
          good: _battery ?? true,
          onTap: SystemBridge.openBatterySettings,
        ),
        if (xiaomiFamily) ...[
          divider,
          status('Autostart (Xiaomi)', 'Turn on for OTDA', onTap: SystemBridge.openAutostart),
        ],
        divider,
        status('Sound and pop-up', 'Reminders channel',
            onTap: () => SystemBridge.openChannelSettings(ReminderService.channelReminders)),
        divider,
        status('Armed reminders', '$_armed'),
        for (final reminder in next) ...[
          divider,
          status('Next', ReminderService.describe(reminder)),
        ],
        if (service.lastError != null) ...[
          divider,
          status('Last error', service.lastError!, good: false),
        ],
        divider,
        action(Icons.notifications_active_outlined, 'Allow notifications',
            'Shows the system permission dialog', _allow),
        action(Icons.notification_add_outlined, 'Show a test notification now',
            'Proves the permission and the sound', () async {
          _say(await service.sendTestNow());
          await _refresh();
        }),
        action(Icons.alarm_outlined, 'Test in 1 minute',
            'Goes through the alarm clock. Lock the phone and swipe the app away', () async {
          _say(await service.scheduleTest(const Duration(minutes: 1)));
          await _refresh();
        }),
        action(Icons.copy_all_outlined, 'Copy debug log',
            'Permissions, what is armed, and recent events. Paste it to share', () async {
          final report = await service.debugReport();
          await Clipboard.setData(ClipboardData(text: report));
          _say('Copied ${report.split('\n').length} lines to the clipboard.');
        }),
        action(Icons.delete_sweep_outlined, 'Clear debug log', 'Start fresh before a test', () async {
          await DebugLog.clear();
          _say('Log cleared.');
        }),
        if (repo != null)
          action(Icons.task_alt_outlined, 'Test with a real task in 2 minutes',
              'Creates a task, arms it, and lets you try Complete and Snooze', () async {
            _say(await service.createRealTest(repo));
            await widget.state.afterDataChanged();
            await _refresh();
          }),
      ],
    );
  }
}


/// The home-screen widget's look: text size, spacing, theme, background and what it
/// lists. Kept on this device (the widget is per device), applied to the widget as
/// soon as a value changes.
class _WidgetCard extends StatefulWidget {
  const _WidgetCard();

  @override
  State<_WidgetCard> createState() => _WidgetCardState();
}

class _WidgetCardState extends State<_WidgetCard> {
  WidgetSettings _settings = const WidgetSettings();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetSettings.load().then((value) {
      if (mounted) {
        setState(() {
          _settings = value;
          _loaded = true;
        });
      }
    });
  }

  /// Shows the change now; writes it (and redraws the widget) when [save] is set,
  /// which a slider does only when the finger lifts.
  void _change(WidgetSettings next, {bool save = true}) {
    setState(() => _settings = next);
    if (save) next.save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 13);
    final s = _settings;
    const divider = Divider(height: 1, indent: 16, endIndent: 16);

    Widget slider({
      required String label,
      required String value,
      required double current,
      required double min,
      required double max,
      required int divisions,
      required void Function(double, {bool save}) onChange,
    }) =>
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(label, style: style)),
                  Text(value,
                      style: style?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                ],
              ),
              Slider(
                value: current.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: _loaded ? (v) => onChange(v, save: false) : null,
                onChangeEnd: _loaded ? (v) => onChange(v, save: true) : null,
              ),
            ],
          ),
        );

    Widget toggle(String label, String subtitle, bool value, WidgetSettings Function(bool) apply) =>
        SwitchListTile(
          dense: true,
          value: value,
          title: Text(label, style: style),
          subtitle: Text(subtitle),
          onChanged: _loaded ? (v) => _change(apply(v)) : null,
        );

    return Column(
      children: [
        // What the text size will look like, at the size chosen.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.radio_button_unchecked, size: 22 * (s.textScalePct / 100).clamp(0.9, 1.3).toDouble(), color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Call Sam',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16 * s.textScalePct / 100, fontWeight: FontWeight.w500),
                  ),
                ),
                if (s.showDue)
                  Text('15:00',
                      style: TextStyle(fontSize: 14 * s.textScalePct / 100, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        slider(
          label: 'Text size',
          value: '${s.textScalePct}%',
          current: s.textScalePct.toDouble(),
          min: WidgetSettings.minTextScale.toDouble(),
          max: WidgetSettings.maxTextScale.toDouble(),
          divisions: (WidgetSettings.maxTextScale - WidgetSettings.minTextScale) ~/ 5,
          onChange: (v, {bool save = true}) => _change(s.copyWith(textScalePct: v.round()), save: save),
        ),
        divider,
        SettingsChoiceRow(
          label: 'Row spacing',
          value: s.density,
          options: const {'compact': 'Compact', 'standard': 'Standard', 'roomy': 'Roomy'},
          onChanged: (v) => _change(s.copyWith(density: v)),
        ),
        divider,
        SettingsChoiceRow(
          label: 'Widget theme',
          value: s.theme,
          options: const {'system': 'Follow the phone', 'light': 'Light', 'dark': 'Dark'},
          onChanged: (v) => _change(s.copyWith(theme: v)),
        ),
        divider,
        slider(
          label: 'Background opacity',
          value: '${s.backgroundPct}%',
          current: s.backgroundPct.toDouble(),
          min: WidgetSettings.minBackground.toDouble(),
          max: WidgetSettings.maxBackground.toDouble(),
          divisions: (WidgetSettings.maxBackground - WidgetSettings.minBackground) ~/ 5,
          onChange: (v, {bool save = true}) => _change(s.copyWith(backgroundPct: v.round()), save: save),
        ),
        divider,
        toggle('Section headings', 'Overdue, Today, Tomorrow…', s.showSections,
            (v) => s.copyWith(showSections: v)),
        divider,
        toggle('Due time and date', 'At the right of each task', s.showDue, (v) => s.copyWith(showDue: v)),
        divider,
        toggle('Completed tasks', 'Keep ticked-off tasks in the list', s.showCompleted,
            (v) => s.copyWith(showCompleted: v)),
        divider,
        ListTile(
          dense: true,
          leading: Icon(Icons.restart_alt, size: 18, color: scheme.primary),
          title: Text('Reset widget look', style: style),
          onTap: _loaded ? () => _change(const WidgetSettings()) : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Applies to every OTDA widget on this phone. Changes show on the home screen right away.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// The account's encryption, where a person looks for it.
///
/// It states what the server has (a key record or not), whether this device holds
/// the key, and the two things worth doing here: unlock it, or lock it away again.
/// Turning encryption on or off stays on the server, because both re-write every
/// field and the safe place for that is the web sign-in with a fresh confirmation.
class _EncryptionCard extends StatefulWidget {
  const _EncryptionCard({required this.state});

  final AppState state;

  @override
  State<_EncryptionCard> createState() => _EncryptionCardState();
}

class _EncryptionCardState extends State<_EncryptionCard> {
  bool _busy = false;

  Future<void> _unlock() async {
    setState(() => _busy = true);
    try {
      final unlocked = await showE2eeUnlockSheet(context);
      if (unlocked) await widget.state.afterUnlock();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lock() async {
    setState(() => _busy = true);
    try {
      await E2eeSession.instance.lock();
      widget.state.e2eeLocked.value = true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 13);
    final session = E2eeSession.instance;
    final encrypted = session.enabled;

    if (!encrypted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('End-to-end encryption', style: style)),
                Text(
                  'Off',
                  style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'This account keeps its content on the server in plaintext. Turn encryption on '
              'in the web app, then sign in here again to unlock it.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final unlocked = session.unlocked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                unlocked ? Icons.lock_open_rounded : Icons.lock_outline,
                size: 18,
                color: unlocked ? theme.colorScheme.primary : theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('End-to-end encryption', style: style)),
              Text(
                unlocked ? 'Unlocked' : 'Locked',
                style: style?.copyWith(
                  color: unlocked ? theme.colorScheme.primary : theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            unlocked
                ? 'This device holds the key, so your tasks are readable and sync works.'
                : 'This device has no key: nothing syncs until you unlock with the passphrase.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!unlocked)
                FilledButton.tonal(
                  onPressed: _busy ? null : _unlock,
                  child: Text(_busy ? 'Unlocking…' : 'Unlock'),
                )
              else
                OutlinedButton(
                  onPressed: _busy ? null : _lock,
                  child: const Text('Lock this device'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The account's second factor: enrol, recovery codes, remembered browsers and
/// turning it off. Every mutating route needs a recent password or code, so the
/// card asks for one when the server answers `reauth_required`.
class _TwoFactorCard extends StatefulWidget {
  const _TwoFactorCard({required this.state});

  final AppState state;

  @override
  State<_TwoFactorCard> createState() => _TwoFactorCardState();
}

class _TwoFactorCardState extends State<_TwoFactorCard> {
  static const _service = MfaService();

  MfaStatus? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = widget.state.client;
    if (client == null) return;
    try {
      final status = await _service.status(client);
      if (mounted) setState(() => _status = status);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.status == 404 ? null : e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Runs a step-up route, asking for the password once when it has expired.
  Future<T> _sensitive<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiException catch (e) {
      if (!e.needsReauth) rethrow;
      final ok = await askReauth(
        context,
        widget.state,
        enrolled: _status?.enrolled ?? false,
      );
      if (!ok) throw const ApiException(0, 'cancelled', 'cancelled');
      return await action();
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _turnOn() async {
    final client = widget.state.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final enrolment = await _sensitive(() => _service.enroll(client));
      if (!mounted) return;
      final confirmation = await _askForCode(client, enrolment);
      if (confirmation == null) return;
      await _showCodes(confirmation.recoveryCodes);
      await _load();
    } on ApiException catch (e) {
      if (e.code != 'cancelled') setState(() => _error = _explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<MfaConfirmation?> _askForCode(
    ApiClient client,
    TotpEnrollment enrolment,
  ) async {
    final code = TextEditingController();
    final busy = ValueNotifier<bool>(false);
    final error = ValueNotifier<String?>(null);
    final result = await showDialog<MfaConfirmation>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Add this key to your authenticator'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'In your authenticator app choose "enter a setup key", then type the six-digit '
                'code it shows.',
              ),
              const SizedBox(height: 14),
              SelectableText(
                enrolment.secret,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontFamily: 'monospace', letterSpacing: 1.5),
              ),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: enrolment.secret),
                  );
                  _say('Key copied');
                },
                child: const Text('Copy key'),
              ),
              TextField(
                controller: code,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Six-digit code'),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: error,
                builder: (context, message, _) => message == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          message,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: busy,
            builder: (context, working, _) => FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      busy.value = true;
                      error.value = null;
                      try {
                        final confirmed = await _service.confirm(
                          client,
                          code.text,
                        );
                        if (context.mounted) {
                          Navigator.of(context).pop(confirmed);
                        }
                      } on ApiException catch (e) {
                        error.value = _explain(e);
                      } finally {
                        busy.value = false;
                      }
                    },
              child: Text(working ? 'Checking…' : 'Turn on'),
            ),
          ),
        ],
      ),
    );
    code.dispose();
    busy.dispose();
    error.dispose();
    return result;
  }

  Future<void> _showCodes(List<String> codes) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save your recovery codes'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Shown once. Each code signs you in if the authenticator is lost.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                codes.join('\n'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1.2,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: codes.join('\n')));
              _say('Recovery codes copied');
            },
            child: const Text('Copy all'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('I saved them'),
          ),
        ],
      ),
    );
  }

  Future<void> _regenerate() async {
    final client = widget.state.client;
    if (client == null) return;
    setState(() => _busy = true);
    try {
      final codes = await _sensitive(
        () => _service.regenerateRecoveryCodes(client),
      );
      await _showCodes(codes);
      await _load();
    } on ApiException catch (e) {
      if (e.code != 'cancelled') _say(_explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    final client = widget.state.client;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off two-factor authentication?'),
        content: const Text(
          'Signing in will need only the password. Remembered browsers and recovery codes stop '
          'working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _sensitive(() => _service.disable(client));
      _say('Two-factor authentication is off');
      await _load();
    } on ApiException catch (e) {
      if (e.code != 'cancelled') {
        _say(
          e.code == 'mfa_required_by_policy'
              ? 'The server owner requires it for this account.'
              : _explain(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _devices() async {
    final client = widget.state.client;
    if (client == null) return;
    List<TrustedDevice> devices;
    try {
      devices = await _sensitive(() => _service.trustedDevices(client));
    } on ApiException catch (e) {
      if (e.code != 'cancelled') _say(_explain(e));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Remembered browsers'),
          content: SizedBox(
            width: 420,
            child: devices.isEmpty
                ? const Text(
                    'None. A browser that ticked "trust this device" will appear here.',
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final device in devices)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            device.userAgent.isEmpty
                                ? 'Unknown browser'
                                : device.userAgent,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            'Added ${_day(device.createdAt)} · expires ${_day(device.expiresAt)}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Forget this browser',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () async {
                              try {
                                await _sensitive(
                                  () => _service.forgetTrustedDevice(
                                    client,
                                    device.id,
                                  ),
                                );
                                setDialogState(() => devices.remove(device));
                              } on ApiException catch (e) {
                                if (e.code != 'cancelled') _say(_explain(e));
                              }
                            },
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            if (devices.isNotEmpty)
              TextButton(
                onPressed: () async {
                  try {
                    await _sensitive(
                      () => _service.forgetAllTrustedDevices(client),
                    );
                    setDialogState(devices.clear);
                  } on ApiException catch (e) {
                    if (e.code != 'cancelled') _say(_explain(e));
                  }
                },
                child: const Text('Forget all'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  static String _day(int ms) {
    if (ms <= 0) return '—';
    final date = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _explain(ApiException e) => switch (e.code) {
    'mfa_code_invalid' => 'That code did not match. Check the phone\'s clock.',
    'mfa_already_enrolled' => 'Two-factor authentication is already on.',
    'mfa_not_enrolled' => 'Two-factor authentication is not on.',
    'reauth_required' => 'Confirm your password to continue.',
    'rate_limited' => 'Too many attempts. Wait a minute.',
    'invalid_input' => 'That was not accepted. Try again.',
    _ => e.message,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 13);
    final status = _status;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final on = status?.enrolled ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                on ? Icons.verified_user_rounded : Icons.shield_outlined,
                size: 18,
                color: on
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('Two-factor authentication', style: style)),
              Text(
                on ? 'On' : 'Off',
                style: style?.copyWith(
                  color: on
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            on
                ? '${status!.recoveryCodesRemaining} recovery code'
                      '${status.recoveryCodesRemaining == 1 ? '' : 's'} left. '
                      '${status.required ? 'The server owner requires it.' : 'Optional for this account.'}'
                : 'A six-digit code from an authenticator app, asked for after the password. '
                      '${status?.required == true ? 'The server owner requires it.' : 'Optional for this account.'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (!on)
                FilledButton.tonal(
                  onPressed: _busy ? null : _turnOn,
                  child: Text(_busy ? 'Starting…' : 'Turn on'),
                ),
              if (on) ...[
                OutlinedButton(
                  onPressed: _busy ? null : _regenerate,
                  child: const Text('New recovery codes'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _devices,
                  child: const Text('Remembered browsers'),
                ),
                TextButton(
                  onPressed: _busy ? null : _turnOff,
                  child: const Text('Turn off'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

