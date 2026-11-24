import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../reminders/service.dart';
import '../system_bridge.dart';
import 'theme.dart';

/// The one-time explanation Android needs before reminders are trustworthy:
/// notification permission, battery optimisation and exact alarms. Shown after
/// the first sign-in, once the vault (if any) is unlocked.
const _seenKey = 'onboarding.notifications.v1';

Future<void> showNotificationOnboardingOnce(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_seenKey) == true) return;
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => const _NotificationOnboarding(),
  );
  await prefs.setBool(_seenKey, true);
}

class _NotificationOnboarding extends StatefulWidget {
  const _NotificationOnboarding();

  @override
  State<_NotificationOnboarding> createState() => _NotificationOnboardingState();
}

class _NotificationOnboardingState extends State<_NotificationOnboarding> with WidgetsBindingObserver {
  bool? _allowed;
  bool? _exact;
  bool? _battery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final allowed = await ReminderService.instance.notificationsEnabled();
    final exact = await ReminderService.instance.exactAlarmsAllowed();
    final battery = await SystemBridge.ignoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _allowed = allowed;
      _exact = exact;
      _battery = battery;
    });
  }

  Future<void> _allow() async {
    await ReminderService.instance.setRemindersEnabled(true);
    final granted = await ReminderService.instance.requestPermission();
    if (!mounted) return;
    if (!granted) await SystemBridge.openNotificationSettings();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.notifications_active_outlined, size: 38, color: scheme.primary),
              const SizedBox(height: 12),
              Text(
                'Keep reminders on time',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Android can delay or silence OTDA reminders when the app is battery-optimised or exact alarms are '
                'blocked. These are system settings; OTDA cannot change them for you.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _StatusRow(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                subtitle: _allowed == true ? 'Allowed' : 'Not allowed yet',
                good: _allowed == true,
                onTap: _allow,
              ),
              _StatusRow(
                icon: Icons.battery_saver_outlined,
                title: 'Battery optimisation',
                subtitle: _battery == true
                    ? 'Unrestricted'
                    : 'Optimised; Android may defer reminders',
                good: _battery == true,
                onTap: SystemBridge.openBatterySettings,
              ),
              _StatusRow(
                icon: Icons.alarm_outlined,
                title: 'Alarms & reminders',
                subtitle: _exact == true ? 'Allowed' : 'Blocked; reminders may be late',
                good: _exact == true,
                onTap: SystemBridge.openExactAlarmSettings,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _allow,
                child: const Text('Allow notifications'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Not now'),
              ),
              Text(
                'You can revisit these from Settings → Notifications.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.good,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool good;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.field,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            await onTap();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
            child: Row(
              children: [
                Icon(icon, size: 20, color: good ? scheme.primary : scheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
