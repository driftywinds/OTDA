import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/cookie_jar.dart';
import '../data/clock.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../data/sync_engine.dart';
import '../widget/snapshot.dart';
import 'planner.dart';

/// A request, from a widget or a link, to open the new-task sheet.
class NewTaskRequest {
  const NewTaskRequest(this.projectId);
  final String? projectId;
}

/// Arms reminders with the OS, routes their actions, and keeps the widget fed.
///
/// The blueprint's single trigger lives here: [rearmFrom] is the only thing that
/// schedules anything, so a tap in the shade, a sync and an edit all land on the
/// same plan.
class ReminderService {
  ReminderService._();
  static final instance = ReminderService._();

  static const channelReminders = 'reminders';
  static const channelDueToday = 'due_today';
  static const channelOverdue = 'overdue';
  static const _accent = Color(0xFF34D399);

  // Ids 1 and 2 are the two test notifications; a plan id is a 31-bit hash and the
  // diff below never cancels these.
  static const _testNowId = 1;
  static const _testLaterId = 2;

  static const _enabledPref = 'notif.enabled';
  static const _timePref = 'notif.default_time';
  static const _askedPref = 'notif.asked.v2';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void>? _initFuture;
  Future<void> _queue = Future.value();

  /// What the last re-arm did, for the Notifications card in Settings.
  List<PlannedReminder> lastPlan = const [];
  DateTime? lastRearmAt;
  String? lastError;

  /// A task to open (from a widget row or a notification tap).
  final pendingTask = ValueNotifier<String?>(null);

  /// The widget's "+" was tapped.
  final pendingNewTask = ValueNotifier<NewTaskRequest?>(null);

  Future<void> init() => _initFuture ??= _init().catchError((Object e) {
        lastError = 'init: $e';
        _initFuture = null;
      });

  Future<void> _init() async {
    tzdata.initializeTimeZones();
    await _setLocalZone();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_otda'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: _onTap,
      onDidReceiveBackgroundNotificationResponse: onReminderAction,
    );
    await _createChannels();
    _ready = true;
    // The app was started by tapping a reminder: open that task once the UI is up.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _openPayload(launch?.notificationResponse?.payload);
    }
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

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  // ---- settings --------------------------------------------------------

  Future<bool> remindersEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(_enabledPref) ?? true;
  }

  Future<void> setRemindersEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledPref, value);
  }

  /// The time a task with a date but no time reminds at, `HH:mm`.
  Future<String> reminderTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(_timePref) ?? defaultReminderTime;
  }

  Future<void> setReminderTime(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_timePref, value);
  }

  // ---- permissions -----------------------------------------------------

  /// Whether Android will show this app's notifications at all.
  Future<bool> notificationsEnabled() async {
    await init();
    return await _android?.areNotificationsEnabled() ?? true;
  }

  /// Shows the system permission dialog (Android 13+). Returns what the person chose;
  /// false also covers "already refused twice", where Android shows nothing.
  Future<bool> requestPermission() async {
    await init();
    final android = _android;
    if (android != null) return await android.requestNotificationsPermission() ?? false;
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
  }

  /// Asks once, the first time there is something to remind about.
  Future<bool> requestPermissionOnce() async {
    await init();
    if (await notificationsEnabled()) return true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedPref) == true) return false;
    final granted = await requestPermission();
    await prefs.setBool(_askedPref, true);
    return granted;
  }

  Future<bool> exactAlarmsAllowed() async {
    await init();
    return await _android?.canScheduleExactNotifications() ?? true;
  }

  // ---- arming ----------------------------------------------------------

  /// Reads the replica and re-arms from it. Safe to call from any isolate.
  Future<void> rearmFrom(Repo repo) async {
    final tasks = await repo.tasks();
    final projects = await repo.projects();
    final snoozes = await repo.snoozes();
    await rearm(
      tasks,
      projectNames: {for (final project in projects) project.id: project.name},
      snoozes: snoozes,
    );
  }

  /// Rebuilds the plan and diffs it against what the OS holds. Calls queue up, so
  /// a re-arm asked for during another one is not lost.
  Future<void> rearm(
    List<Task> tasks, {
    Map<String, String> projectNames = const {},
    Map<String, DateTime> snoozes = const {},
  }) {
    final run = _queue.then((_) => _rearmNow(tasks, projectNames, snoozes));
    _queue = run.catchError((Object _) {});
    return run;
  }

  Future<void> _rearmNow(
    List<Task> tasks,
    Map<String, String> projectNames,
    Map<String, DateTime> snoozes,
  ) async {
    try {
      await init();
      if (!_ready) return;
      final enabled = await remindersEnabled();
      final pending = await _plugin.pendingNotificationRequests();
      if (!enabled) {
        for (final request in pending) {
          if (request.id != _testNowId && request.id != _testLaterId) await _plugin.cancel(id: request.id);
        }
        lastPlan = const [];
        lastRearmAt = DateTime.now();
        lastError = null;
        return;
      }
      final plan = planReminders(
        tasks,
        now: DateTime.now(),
        zone: tz.local,
        defaultTime: await reminderTime(),
        projectNames: projectNames,
        snoozedUntil: {
          for (final entry in snoozes.entries) entry.key: tz.TZDateTime.from(entry.value, tz.local),
        },
      );
      final wanted = {for (final reminder in plan) reminder.id};
      for (final request in pending) {
        if (request.id == _testNowId || request.id == _testLaterId) continue;
        if (!wanted.contains(request.id)) await _plugin.cancel(id: request.id);
      }
      final exact = await exactAlarmsAllowed();
      for (final reminder in plan) {
        await _schedule(reminder.id, reminder.title, reminder.body, reminder.at, reminder.payload, exact);
      }
      lastPlan = plan;
      lastRearmAt = DateTime.now();
      lastError = null;
    } on Object catch (e) {
      // A missing permission or a plugin gap must not take the app down, but it must
      // be visible: the Notifications card shows this line.
      lastError = '$e';
    }
  }

  Future<void> _schedule(int id, String title, String body, tz.TZDateTime at, String payload, bool exact) async {
    Future<void> go(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: at,
          notificationDetails: _details(),
          androidScheduleMode: mode,
          payload: payload,
        );
    if (!exact) return go(AndroidScheduleMode.inexactAllowWhileIdle);
    try {
      await go(AndroidScheduleMode.exactAllowWhileIdle);
    } on PlatformException {
      // The exact-alarm grant was revoked between the check and the call.
      await go(AndroidScheduleMode.inexactAllowWhileIdle);
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

  // ---- testing ---------------------------------------------------------

  static const _blocked = 'Notifications are blocked for OTDA. Tap "Allow notifications" first.';

  /// Posts a notification right now. Proves the permission and the channel.
  Future<String> sendTestNow() async {
    await init();
    if (!await notificationsEnabled()) return _blocked;
    await _plugin.show(
      id: _testNowId,
      title: 'Reminder test',
      body: 'If you can read this, notifications are allowed.',
      notificationDetails: _details(),
      payload: 'test',
    );
    return 'Sent. Pull down the notification shade.';
  }

  /// Hands a notification to AlarmManager for [after] from now, exactly like a real
  /// reminder. Lock the phone, close the app and wait: this is the realistic check.
  Future<String> scheduleTest(Duration after) async {
    await init();
    if (!await notificationsEnabled()) return _blocked;
    final at = tz.TZDateTime.now(tz.local).add(after);
    final exact = await exactAlarmsAllowed();
    await _schedule(_testLaterId, 'Scheduled reminder test',
        'This one came from the alarm clock, not from the open app.', at, 'test', exact);
    final clock = _clock(at);
    return exact
        ? 'Scheduled for $clock. Lock the phone, swipe the app away and wait.'
        : 'Scheduled for about $clock, but exact alarms are off so Android may deliver it late.';
  }

  /// Creates a real task due in [after] and arms it, so the whole path (task, plan,
  /// alarm, notification, Complete button) is exercised. Delete the task afterwards.
  Future<String> createRealTest(Repo repo, {Duration after = const Duration(minutes: 2)}) async {
    final due = DateTime.now().add(after);
    final date = '${due.year.toString().padLeft(4, '0')}-'
        '${due.month.toString().padLeft(2, '0')}-'
        '${due.day.toString().padLeft(2, '0')}';
    await repo.createTask('Test reminder (safe to delete)', extra: {
      'due': {'date': date, 'time': '${_two(due.hour)}:${_two(due.minute)}'},
    });
    await rearmFrom(repo);
    if (lastError != null) return 'Task created, but arming failed: $lastError';
    return 'Task created for ${_two(due.hour)}:${_two(due.minute)}. Lock the phone and wait, '
        'then try the Complete button.';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

  Future<List<PendingNotificationRequest>> pending() async {
    await init();
    return _plugin.pendingNotificationRequests();
  }

  Future<int> armedCount() async => (await pending()).length;

  /// Formats a planned time for the Settings list.
  static String describe(PlannedReminder reminder) =>
      '${reminder.day} ${_clock(reminder.at)}  ${reminder.title}';

  // ---- taps ------------------------------------------------------------

  void _onTap(NotificationResponse response) => _openPayload(response.payload);

  /// A payload is `taskId|day`; a test notification carries none and opens nothing.
  void _openPayload(String? payload) {
    if (payload == null || !payload.contains('|')) return;
    pendingTask.value = payload.split('|').first;
  }
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
      final time = (await ReminderService.instance.reminderTime()).split(':');
      final at = DateTime(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        int.tryParse(time.first) ?? 9,
        time.length > 1 ? int.tryParse(time[1]) ?? 0 : 0,
      );
      await repo.setSnooze(taskId, day, at);
    default:
      return;
  }
  await ReminderService.instance.rearmFrom(repo);
  await pushWidgetsFromRepo(repo);
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

String _todayString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

/// Why the last widget push failed, or null. Shown nowhere yet but kept for logs.
String? lastWidgetError;

/// Reads the replica and pushes every widget snapshot from it. Works with no UI.
Future<void> pushWidgetsFromRepo(Repo repo) async {
  final tasks = await repo.tasks();
  final projects = await repo.projects();
  await pushWidgets(tasks, projects, today: _todayString());
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
    await HomeWidget.saveWidgetData<bool>('refreshing', false);
    await HomeWidget.updateWidget(
      androidName: 'TasksWidgetReceiver',
      qualifiedAndroidName: 'com.dw.otda.widget.TasksWidgetReceiver',
    );
    lastWidgetError = null;
  } on Object catch (e) {
    // No widget placed, or no launcher support: nothing to do.
    lastWidgetError = '$e';
  }
}

/// Routes a link from the widget or a notification. Called with the launching
/// link at start-up and with every later tap while the app is running.
Future<void> handleWidgetUri(Uri? uri) async {
  if (uri == null) return;
  switch (uri.host) {
    case 'task':
      if (uri.pathSegments.isNotEmpty) ReminderService.instance.pendingTask.value = uri.pathSegments.first;
    case 'new':
      ReminderService.instance.pendingNewTask.value = NewTaskRequest(uri.queryParameters['project']);
    case 'complete':
    case 'refresh':
      await onWidgetAction(uri);
    default:
      // upcoming: the app already opens on it.
      break;
  }
}

/// A widget button arrives as a deep link, run in a background isolate when the
/// app is not open.
@pragma('vm:entry-point')
Future<void> onWidgetAction(Uri? uri) async {
  if (uri == null) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final repo = await openHeadlessRepo();
  if (uri.host == 'complete') {
    final taskId = uri.queryParameters['id'];
    if (taskId == null) return;
    final task = (await repo.tasks()).where((t) => t.id == taskId).firstOrNull;
    if (task != null) await repo.setCompleted(task, true);
    await ReminderService.instance.rearmFrom(repo);
  }
  // Complete, refresh and "no snapshot yet" all end the same way: rewrite every
  // snapshot from the real data, which also clears a stuck "refreshing" flag.
  await pushWidgetsFromRepo(repo);
}
