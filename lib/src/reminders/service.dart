import 'dart:async' show unawaited;
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
import '../data/recurrence.dart' show isRecurring;
import '../data/repo.dart';
import '../data/series.dart' show currentOccurrence, occurrenceDateOf;
import '../auth/session_store.dart';
import '../data/sync_engine.dart';
import '../e2ee/session.dart';
import '../widget/snapshot.dart';
import 'debug_log.dart';
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
  static const _alarmClockPref = 'notif.alarm_clock';

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
        return DebugLog.add('init FAILED: $e', source: _source);
      });

  /// Which isolate is logging: the app, or a notification/widget background callback.
  static String _source = 'app';
  static void markBackground() => _source = 'bg';

  Future<void> _init() async {
    await DebugLog.add('init: start', source: _source);
    tzdata.initializeTimeZones();
    await _setLocalZone();
    Future<void> initWith(String icon) => _plugin.initialize(
          settings: InitializationSettings(
            android: AndroidInitializationSettings(icon),
            iOS: const DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
            ),
          ),
          onDidReceiveNotificationResponse: _onTap,
          onDidReceiveBackgroundNotificationResponse: onReminderAction,
        );
    try {
      await initWith('ic_stat_otda');
    } on PlatformException catch (e) {
      // The status-bar icon was stripped from the build. Fall back to the launcher icon so
      // reminders still work (Android draws it as a plain square) instead of failing outright.
      await DebugLog.add('init: icon ic_stat_otda rejected: ${e.code}; using launcher icon', source: _source);
      await initWith('@mipmap/ic_launcher');
    }
    await _createChannels();
    _ready = true;
    await DebugLog.add('init: ok, zone=${tz.local.name}', source: _source);
    // The app was started by tapping a reminder: open that task once the UI is up.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      await DebugLog.add('launched by notification ${launch?.notificationResponse?.payload}', source: _source);
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

  /// Alarm-clock mode: Android treats the reminder like a real alarm, so phone makers'
  /// battery managers (Xiaomi, Oppo, ...) do not defer it. The cost is a small alarm icon in
  /// the status bar while a reminder is pending. On by default until the phone proves it is
  /// not needed.
  Future<bool> alarmClockMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(_alarmClockPref) ?? true;
  }

  Future<void> setAlarmClockMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_alarmClockPref, value);
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
      if (!_ready) {
        await DebugLog.add('rearm: skipped, notifications not initialised ($lastError)', source: _source);
        return;
      }
      final enabled = await remindersEnabled();
      final pending = await _plugin.pendingNotificationRequests();
      await DebugLog.add(
          'rearm: ${tasks.length} tasks, ${snoozes.length} snoozes, enabled=$enabled, ${pending.length} pending before',
          source: _source);
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
      await DebugLog.add('rearm: plan has ${plan.length} reminder(s), exact=$exact', source: _source);
      String? firstFailure;
      for (final reminder in plan) {
        try {
          await _schedule(reminder.id, reminder.title, reminder.body, reminder.at, reminder.payload, exact);
          await DebugLog.add('armed #${reminder.id} "${reminder.title}" at ${reminder.at}', source: _source);
        } on Object catch (e) {
          firstFailure ??= '$e';
          await DebugLog.add('arm FAILED #${reminder.id} "${reminder.title}": $e', source: _source);
        }
      }
      lastPlan = plan;
      lastRearmAt = DateTime.now();
      lastError = firstFailure;
      final after = await _plugin.pendingNotificationRequests();
      await DebugLog.add('rearm: done, ${after.length} pending in the OS', source: _source);
    } on Object catch (e) {
      // A missing permission or a plugin gap must not take the app down, but it must
      // be visible: the Notifications card shows this line.
      lastError = '$e';
      await DebugLog.add('rearm FAILED: $e', source: _source);
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
    final modes = <AndroidScheduleMode>[
      if (await alarmClockMode()) AndroidScheduleMode.alarmClock,
      if (exact) AndroidScheduleMode.exactAllowWhileIdle,
      AndroidScheduleMode.inexactAllowWhileIdle,
    ];
    for (var i = 0; i < modes.length; i++) {
      try {
        await go(modes[i]);
        if (i > 0) await DebugLog.add('schedule #$id: fell back to ${modes[i].name}', source: _source);
        return;
      } on PlatformException catch (e) {
        // A grant was revoked between the check and the call: try the next weaker mode.
        await DebugLog.add('schedule #$id: ${modes[i].name} refused: ${e.code}', source: _source);
        if (i == modes.length - 1) rethrow;
      }
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
    if (!_ready) return 'Notification setup failed: $lastError';
    if (!await notificationsEnabled()) return _blocked;
    await DebugLog.add('test: show now', source: _source);
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
    if (!_ready) return 'Notification setup failed: $lastError';
    if (!await notificationsEnabled()) return _blocked;
    final at = tz.TZDateTime.now(tz.local).add(after);
    final exact = await exactAlarmsAllowed();
    await DebugLog.add('test: schedule for $at exact=$exact', source: _source);
    try {
      await _schedule(_testLaterId, 'Scheduled reminder test',
          'This one came from the alarm clock, not from the open app.', at, 'test', exact);
    } on Object catch (e) {
      await DebugLog.add('test: schedule FAILED: $e', source: _source);
      return 'Scheduling failed: $e';
    }
    final pendingNow = await _plugin.pendingNotificationRequests();
    await DebugLog.add(
        'test: scheduled, pending ids=${pendingNow.map((r) => r.id).toList()}', source: _source);
    final clock = _clock(at);
    if (await alarmClockMode()) return 'Scheduled for $clock in alarm-clock mode. Lock the phone and swipe the app away.';
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
    await DebugLog.add('test: real task created for $date ${_two(due.hour)}:${_two(due.minute)}', source: _source);
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

  // ---- debug report ----------------------------------------------------

  /// Everything needed to see why a reminder or the widget misbehaves, as plain text.
  Future<String> debugReport() async {
    final out = StringBuffer('OTDA reminders debug report\n');
    Future<void> line(String label, Future<Object?> Function() value) async {
      try {
        out.writeln('$label: ${await value()}');
      } on Object catch (e) {
        out.writeln('$label: ERROR $e');
      }
    }

    out.writeln('now: ${DateTime.now()}  zone: ${tz.local.name}');
    await init();
    out.writeln('initialised: $_ready  lastError: $lastError');
    out.writeln('lastRearmAt: $lastRearmAt');
    await line('reminders enabled', remindersEnabled);
    await line('default time', reminderTime);
    await line('notifications allowed', notificationsEnabled);
    await line('exact alarms allowed', exactAlarmsAllowed);
    await line('alarm-clock mode', alarmClockMode);
    await line('widget active_projects', () => HomeWidget.getWidgetData<String>('active_projects'));
    await line('widget snapshot_all length',
        () async => (await HomeWidget.getWidgetData<String>('snapshot_all'))?.length);
    await line('widget projects_index length',
        () async => (await HomeWidget.getWidgetData<String>('projects_index'))?.length);
    out.writeln('lastWidgetError: $lastWidgetError');
    try {
      final pending = await _plugin.pendingNotificationRequests();
      out.writeln('pending in the OS: ${pending.length}');
      for (final request in pending) {
        out.writeln('  #${request.id} "${request.title}" ${request.body} payload=${request.payload}');
      }
    } on Object catch (e) {
      out.writeln('pending in the OS: ERROR $e');
    }
    out.writeln('last plan (${lastPlan.length}):');
    for (final reminder in lastPlan) {
      out.writeln('  #${reminder.id} ${reminder.at} "${reminder.title}"');
    }
    out.writeln('--- log (oldest first) ---');
    for (final entry in await DebugLog.read()) {
      out.writeln(entry);
    }
    return out.toString();
  }

  // ---- taps ------------------------------------------------------------

  void _onTap(NotificationResponse response) {
    unawaited(DebugLog.add('tap payload=${response.payload} action=${response.actionId}', source: _source));
    _openPayload(response.payload);
  }

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
  ReminderService.markBackground();
  final payload = response.payload;
  await DebugLog.add('action ${response.actionId} payload=$payload', source: 'bg');
  if (payload == null || !payload.contains('|')) return;
  final parts = payload.split('|');
  final taskId = parts[0];
  final day = parts[1];

  final Repo repo;
  try {
    repo = await openHeadlessRepo();
  } on Object catch (e) {
    await DebugLog.add('action: could not open the database: $e', source: 'bg');
    return;
  }
  final task = (await repo.tasks()).where((t) => t.id == taskId).firstOrNull;
  if (task == null) {
    await DebugLog.add('action: task $taskId not found', source: 'bg');
    return;
  }

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
  await DebugLog.add('action ${response.actionId}: done, re-arming', source: 'bg');
  // The widget goes first: it must never wait for the reminders to be re-armed.
  await pushWidgetsFromRepo(repo);
  await ReminderService.instance.rearmFrom(repo);
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

/// One real exchange with the server for the widget's Refresh button, with no UI. The headless repo
/// has a dummy client, so without this a refresh only re-read what the app had already synced.
/// Skipped (the local snapshot is still rebuilt) when signed out, offline, or end-to-end encrypted:
/// a pull without the unlocked key would store ciphertext.
Future<void> syncHeadless(Repo repo) async {
  try {
    final stored = await SessionStore().read();
    if (stored == null) return;
    await E2eeSession.instance.restore();
    if (E2eeSession.instance.enabled) return;
    final client = ApiClient(
      baseUrl: Uri.parse(stored.serverUrl),
      jar: CookieJar(stored.jar.cookies),
      token: stored.token,
    );
    final engine = SyncEngine(db: repo.db, client: client, clock: repo.clock);
    await engine.open();
    if (!engine.fullSyncDone) return;
    await engine.exchange().timeout(const Duration(seconds: 15));
    await DebugLog.add('widget refresh: synced', source: 'bg');
  } on Object catch (e) {
    await DebugLog.add('widget refresh: sync failed: $e', source: 'bg');
  }
}

/// The newest widget tap the app has applied (`pending_ack`, advanced only here).
Future<int> _widgetAck() async =>
    int.tryParse(await HomeWidget.getWidgetData<String>('pending_ack') ?? '') ?? 0;

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty || text == 'null' ? null : text;
}

/// Applies ticks and un-ticks made on the widget (`pending_ops`, written natively) to the replica, in
/// order, and records progress in `pending_ack`. The widget already shows them; this makes them real.
/// Returns how many changed the replica.
///
/// Each op is applied by what it *means* against what the replica holds now, never by replaying a write,
/// so applying one a second time (two isolates, a lost ack) changes nothing. That matters for a repeating
/// task: ticking it moves the series on, so a replayed tick would tick tomorrow's occurrence as well.
Future<int> applyPendingWidgetOps(Repo repo) async {
  var applied = 0;
  try {
    final raw = await HomeWidget.getWidgetData<String>('pending_ops');
    if (raw == null || raw.isEmpty) return 0;
    var ack = await _widgetAck();
    final ops = (jsonDecode(raw) as List)
        .whereType<Map>()
        .where((op) => ((op['at'] as num?)?.toInt() ?? 0) > ack)
        .toList()
      ..sort((a, b) => ((a['at'] as num?) ?? 0).compareTo((b['at'] as num?) ?? 0));
    if (ops.isEmpty) return 0;
    for (final op in ops) {
      if (await applyWidgetOp(repo, op)) applied++;
      final at = (op['at'] as num).toInt();
      // Never move the ack backwards: another isolate may have got further while this one worked.
      if (at > ack) {
        ack = at;
        if (at > await _widgetAck()) await HomeWidget.saveWidgetData<String>('pending_ack', '$at');
      }
    }
  } on Object catch (e) {
    await DebugLog.add('widget: applying pending ops failed: $e', source: ReminderService._source);
  }
  return applied;
}

/// One widget tap against the replica as it is now. True when it changed something.
/// Public only so the tests can drive it without the home_widget platform channel.
Future<bool> applyWidgetOp(Repo repo, Map op) async {
  final id = _nonEmpty(op['id']);
  if (id == null) return false;
  final done = op['done'] != false;
  final day = _nonEmpty(op['day']);
  final sid = _nonEmpty(op['sid']);
  final occ = _nonEmpty(op['occ']);
  final seriesId = sid ?? id;
  final tasks = await repo.tasks();
  Task? find(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  final tapped = find(id);
  final series = find(seriesId);
  final today = _todayString();

  if (done) {
    // The row tapped may be gone already (a tick that was un-ticked: its record is deleted), in which
    // case the series is what the person ticked again.
    final task = tapped ?? series;
    if (task == null || task.isCompleted) return false;
    final isSeries = isRecurring(task) && (task.raw['series_id']?.toString() ?? '').isEmpty;
    if (isSeries) {
      // Only the occurrence the row stood for. If the series has moved on, this tap was already applied.
      final current = currentOccurrence(task, tasks, today) ?? occurrenceDateOf(task, today);
      final wanted = occ ?? day;
      if (wanted != null && wanted != current) {
        await DebugLog.add('widget: tick of ${task.id} for $wanted ignored, series is on $current',
            source: ReminderService._source);
        return false;
      }
    }
    await repo.setCompleted(task, true);
    return true;
  }

  // Un-tick. A repeating task's tick left a record for that date: reopening the series row means
  // undoing that record, whichever of the two ids the tap carried.
  final wantedOcc = occ ?? day;
  if (series != null && wantedOcc != null && isRecurring(series)) {
    for (final task in tasks) {
      if (task.raw['series_id']?.toString() == series.id &&
          task.raw['occurrence_date']?.toString() == wantedOcc &&
          task.isCompleted) {
        await repo.setCompleted(task, false);
        return true;
      }
    }
  }
  if (tapped != null && tapped.isCompleted) {
    await repo.setCompleted(tapped, false);
    return true;
  }
  return false;
}

String _todayString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

/// Why the last widget push failed, or null. Shown nowhere yet but kept for logs.
String? lastWidgetError;

/// Redraws the widget and re-arms reminders after a task changes in the UI. Every
/// completion path goes through here: without it, ticking a task in the app left
/// the widget showing the old row until some unrelated sync or reminder re-armed.
/// The widget goes first: it must never wait for the reminders.
Future<void> refreshTaskSurfaces(Repo repo) async {
  await pushWidgetsFromRepo(repo);
  await ReminderService.instance.rearmFrom(repo);
}

Future<void>? _pushLoop;
bool _pushAgain = false;
Repo? _pushRepo;

/// Reads the replica and pushes every widget snapshot from it. Works with no UI.
///
/// Pushes in one isolate run one at a time and coalesce: a call made while a push is running makes the
/// running one go round once more, so the last word is always built from the newest data, and two pushes
/// never interleave their reads and writes (which is how a stale snapshot used to land on top of a
/// fresher one).
Future<void> pushWidgetsFromRepo(Repo repo) {
  _pushRepo = repo;
  final running = _pushLoop;
  if (running != null) {
    _pushAgain = true;
    return running;
  }
  return _pushLoop = _runPushLoop();
}

Future<void> _runPushLoop() async {
  try {
    do {
      _pushAgain = false;
      try {
        await _pushWidgetsOnce(_pushRepo!);
      } on Object catch (e) {
        lastWidgetError = '$e';
        await DebugLog.add('widget: push FAILED: $e', source: ReminderService._source);
      }
    } while (_pushAgain);
  } finally {
    _pushLoop = null;
    // A caller may have arrived after the loop's last check but before this
    // clear; without the second look that request would be dropped and the
    // widget would keep the old snapshot until some unrelated push.
    if (_pushAgain) {
      _pushAgain = false;
      unawaited(pushWidgetsFromRepo(_pushRepo!));
    }
  }
}

Future<void> _pushWidgetsOnce(Repo repo) async {
  // Changes made on the widget come first, so a snapshot never undoes a tick the person just made.
  final applied = await applyPendingWidgetOps(repo);
  // Read the ack BEFORE the data: the snapshot then claims no more than it holds, and a tap that lands
  // after this point is laid over it natively instead of being lost.
  final ack = await _widgetAck();
  final tasks = await repo.tasks();
  final projects = await repo.projects();
  await pushWidgets(tasks, projects, today: _todayString(), ack: ack);
  // Reminders follow the ticks that were just applied, but only after the widget is redrawn.
  if (applied > 0) {
    try {
      await ReminderService.instance.rearmFrom(repo);
    } on Object catch (e) {
      await DebugLog.add('widget: re-arm after ticks failed: $e', source: ReminderService._source);
    }
  }
}

/// Writes the widget snapshots for the projects that have a widget and asks the
/// launcher to redraw. The native side never computes anything.
Future<void> pushWidgets(List<Task> tasks, List<Project> projects,
    {required String today, int? ack}) async {
  try {
    final active = await HomeWidget.getWidgetData<String>('active_projects') ?? '';
    final ids = active.split(',').where((id) => id.trim().isNotEmpty).toSet();
    // A widget bound to a project whose binding the native side has not listed
    // would read a snapshot nobody wrote, so every project gets one. There are a
    // handful, and each is capped at a few rows.
    final every = {for (final project in projects) project.id};
    final snapshots = buildWidgetSnapshots(
      tasks,
      projects,
      projectIds: {...ids, ...every, 'all'},
      today: today,
      ack: ack,
    );
    for (final entry in snapshots.entries) {
      await HomeWidget.saveWidgetData<String>('snapshot_${entry.key}', jsonEncode(entry.value));
    }
    await HomeWidget.saveWidgetData<String>('projects_index', jsonEncode(projectsIndex(projects)));
    await HomeWidget.saveWidgetData<bool>('refreshing', false);
    await HomeWidget.updateWidget(
      androidName: 'TasksWidgetReceiver',
      qualifiedAndroidName: 'com.dw.otda.widget.TasksWidgetReceiver',
    );
    lastWidgetError = null;
    await DebugLog.add('widget: pushed ${ids.length} project snapshot(s) + all, ${tasks.length} tasks, ack=$ack',
        source: ReminderService._source);
  } on Object catch (e) {
    // No widget placed, or no launcher support: nothing to do.
    lastWidgetError = '$e';
    await DebugLog.add('widget: push FAILED: $e', source: ReminderService._source);
  }
}

/// Routes a link from the widget or a notification. Called with the launching
/// link at start-up and with every later tap while the app is running.
Future<void> handleWidgetUri(Uri? uri) async {
  if (uri == null) return;
  await DebugLog.add('link: $uri', source: ReminderService._source);
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
  ReminderService.markBackground();
  await DebugLog.add('widget action: $uri', source: 'bg');
  final Repo repo;
  try {
    repo = await openHeadlessRepo();
  } on Object catch (e) {
    await DebugLog.add('widget action: could not open the database: $e', source: 'bg');
    return;
  }
  if (uri.host == 'refresh') await syncHeadless(repo);
  // Complete, refresh and "no snapshot yet" all end the same way: rewrite every
  // snapshot from the real data, which also clears a stuck "refreshing" flag.
  await pushWidgetsFromRepo(repo);
}
