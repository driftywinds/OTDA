import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/api_client.dart';
import '../api/cookie_jar.dart';
import '../data/clock.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../data/sync_engine.dart';
import '../widget/snapshot.dart';
import 'planner.dart';

/// Arms reminders with the OS, routes their actions, and keeps the widget fed.
///
/// The blueprint's single trigger lives here: [afterChange] is the only thing that
/// schedules anything, so a tap in the shade, a sync and an edit all land on the
/// same plan.
class ReminderService {
  ReminderService._();
  static final instance = ReminderService._();

  static const channelReminders = 'reminders';
  static const channelDueToday = 'due_today';
  static const channelOverdue = 'overdue';
  static const _accent = Color(0xFF34D399);

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _rearming = false;
  Timer? _debounce;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    await _setLocalZone();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_otda'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: _onTap,
      onDidReceiveBackgroundNotificationResponse: onReminderAction,
    );
    await _createChannels();
    _ready = true;
  }

  Future<void> _setLocalZone() async {
    try {
      // v5 returns an object, older versions a string; accept both.
      final dynamic raw = await FlutterTimezone.getLocalTimezone();
      final name = raw is String ? raw : raw.identifier as String;
      tz.setLocalLocation(tz.getLocation(name));
    } on Object {
      // UTC is a safe fallback: the plan still fires, only the zone name is wrong.
    }
  }

  Future<void> _createChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    await android.createNotificationChannel(const AndroidNotificationChannel(
      channelReminders,
      'Reminders',
      description: 'A task reminder at its own time',
      importance: Importance.high,
      playSound: true,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      channelDueToday,
      'Due today',
      description: "A morning summary of today's tasks",
      importance: Importance.defaultImportance,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      channelOverdue,
      'Overdue',
      description: 'A quiet nudge for things that slipped',
      importance: Importance.low,
      playSound: false,
    ));
  }

  /// Asks for the notification permission (Android 13+). Call it when a reminder is
  /// first created, never at launch.
  Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  Future<bool> exactAlarmsAllowed() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await android?.canScheduleExactNotifications() ?? true;
  }

  /// Rebuilds the plan and diffs it against what the OS holds.
  Future<void> rearm(List<Task> tasks, {Map<String, String> projectNames = const {}}) async {
    if (_rearming || !_ready) return;
    _rearming = true;
    try {
      final plan = planReminders(tasks, now: DateTime.now(), zone: tz.local, projectNames: projectNames);
      final pending = await _plugin.pendingNotificationRequests();
      final wanted = {for (final reminder in plan) reminder.id};
      for (final request in pending) {
        if (!wanted.contains(request.id)) await _plugin.cancel(id: request.id);
      }
      final exact = await exactAlarmsAllowed();
      for (final reminder in plan) {
        await _plugin.zonedSchedule(
          id: reminder.id,
          title: reminder.title,
          body: reminder.body,
          scheduledDate: reminder.at,
          notificationDetails: _details(),
          androidScheduleMode: exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
          payload: reminder.payload,
        );
      }
    } on Object {
      // A missing permission or a plugin gap must not take the app down.
    } finally {
      _rearming = false;
    }
  }

  NotificationDetails _details() => const NotificationDetails(
        android: AndroidNotificationDetails(
          channelReminders,
          'Reminders',
          channelDescription: 'A task reminder at its own time',
          importance: Importance.high,
          priority: Priority.high,
          color: _accent,
          category: AndroidNotificationCategory.reminder,
          onlyAlertOnce: true,
          actions: [
            AndroidNotificationAction('complete', 'Complete',
                showsUserInterface: false, cancelNotification: true),
            AndroidNotificationAction('snooze_10', 'Snooze 10 min',
                showsUserInterface: false, cancelNotification: true),
            AndroidNotificationAction('snooze_tomorrow', 'Tomorrow',
                showsUserInterface: false, cancelNotification: true),
          ],
        ),
        iOS: DarwinNotificationDetails(threadIdentifier: channelReminders),
      );

  /// Every plan rebuild goes through here, debounced so a burst of edits arms once.
  void afterChange(List<Task> tasks, {Map<String, String> projectNames = const {}}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(rearm(tasks, projectNames: projectNames));
    });
  }

  Future<void> showTest() async {
    await init();
    await _plugin.show(
      id: 1,
      title: 'Reminder test',
      body: 'If this arrived, reminders are working.',
      notificationDetails: _details(),
    );
  }

  Future<List<PendingNotificationRequest>> pending() async {
    await init();
    return _plugin.pendingNotificationRequests();
  }

  void _onTap(NotificationResponse response) {
    // The payload is taskId|day; opening the sheet belongs to the UI, which reads
    // this through the callback the app registers.
    onReminderTapped?.call(response.payload);
  }

  /// Set by the app so a tap on the body can open the task.
  void Function(String? payload)? onReminderTapped;
}

/// Handles a notification action from a background isolate.
@pragma('vm:entry-point')
Future<void> onReminderAction(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final payload = response.payload;
  if (payload == null || !payload.contains('|')) return;
  final parts = payload.split('|');
  final taskId = parts[0];
  final day = parts[1];

  final repo = await openHeadlessRepo();
  final task = (await repo.tasks()).where((t) => t.id == taskId).firstOrNull;
  if (task == null) return;

  switch (response.actionId) {
    case 'complete':
      await repo.setCompleted(task, true);
    case 'snooze_10':
      await repo.setSnooze(taskId, day, DateTime.now().add(const Duration(minutes: 10)));
    case 'snooze_tomorrow':
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final at = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
      await repo.setSnooze(taskId, day, at);
    default:
      return;
  }
  await ReminderService.instance.init();
  await ReminderService.instance.rearm(await repo.tasks());
}

/// Opens the replica without any UI and without a network client.
Future<Repo> openHeadlessRepo() async {
  final dir = await databaseFactory.getDatabasesPath();
  final files = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.db'))
      .toList()
    ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  if (files.isEmpty) throw StateError('no replica on this device');
  final db = await OtdaDb.open(path: p.normalize(files.first.path));
  final clock = await HybridClock.load(db);
  final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
  final engine = SyncEngine(db: db, client: client, clock: clock);
  await engine.open();
  return Repo(db: db, clock: clock, engine: engine);
}

/// Writes the widget snapshots for the projects that have a widget and asks the
/// launcher to redraw. The native side never computes anything.
Future<void> pushWidgets(List<Task> tasks, List<Project> projects, {required String today}) async {
  try {
    final active = await HomeWidget.getWidgetData<String>('active_projects') ?? '';
    final ids = active.split(',').where((id) => id.trim().isNotEmpty).toSet();
    for (final id in {...ids, 'all'}) {
      final snapshot = buildWidgetSnapshot(
        tasks,
        projects,
        projectId: id == 'all' ? null : id,
        today: today,
      );
      await HomeWidget.saveWidgetData<String>('snapshot_$id', jsonEncode(snapshot));
    }
    await HomeWidget.saveWidgetData<String>('projects_index', jsonEncode(projectsIndex(projects)));
    await HomeWidget.updateWidget(
      androidName: 'TasksWidgetReceiver',
      qualifiedAndroidName: 'com.dw.otda.widget.TasksWidgetReceiver',
    );
  } on Object {
    // No widget placed, or no launcher support: nothing to do.
  }
}

/// A widget or notification action arrives as a deep link.
@pragma('vm:entry-point')
Future<void> onWidgetAction(Uri? uri) async {
  if (uri == null) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final repo = await openHeadlessRepo();
  if (uri.host == 'complete') {
    final taskId = uri.queryParameters['id'];
    final day = uri.queryParameters['day'];
    if (taskId == null || day == null) return;
    final task = (await repo.tasks()).where((t) => t.id == taskId).firstOrNull;
    if (task != null) await repo.setCompleted(task, true);
    await ReminderService.instance.init();
    await ReminderService.instance.rearm(await repo.tasks());
  }
}

/// iOS launch arguments for home_widget are a no-op on Android; kept for symmetry.
const homeWidgetUri = 'otda://complete';
