import 'dart:async';

import 'package:flutter/services.dart';

/// The Android side of things Dart cannot reach on its own: `otda://` links from the
/// widget and notifications, and the system screens a reminder depends on.
///
/// Every call swallows a missing platform (tests, iOS, desktop) and answers with a
/// harmless default, so callers never need a try/catch.
class SystemBridge {
  SystemBridge._();

  static const _channel = MethodChannel('com.dw.otda/system');
  static const _complete = MethodChannel('com.dw.otda/complete');
  static void Function(Uri uri)? _onLink;

  /// Delivers the link that launched the app (if any) and every later one.
  static Future<void> listen(void Function(Uri uri) onLink) async {
    _onLink = onLink;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link') {
        final uri = Uri.tryParse(call.arguments as String? ?? '');
        if (uri != null) _onLink?.call(uri);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      final uri = initial == null ? null : Uri.tryParse(initial);
      if (uri != null) onLink(uri);
    } on Object {
      // no platform side: nothing launched us
    }
  }

  static Future<bool> _call(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on Object {
      return false;
    }
  }

  static Future<String> manufacturer() async {
    try {
      return await _channel.invokeMethod<String>('manufacturer') ?? '';
    } on Object {
      return '';
    }
  }

  /// True when Android is allowed to keep the app running in the background freely.
  static Future<bool> ignoringBatteryOptimizations() => _call('isIgnoringBatteryOptimizations');

  static Future<bool> openNotificationSettings() => _call('openNotificationSettings');
  static Future<bool> openChannelSettings(String id) => _call('openChannelSettings', {'id': id});
  static Future<bool> openExactAlarmSettings() => _call('openExactAlarmSettings');
  static Future<bool> openBatterySettings() => _call('openBatterySettings');
  static Future<bool> openAutostart() => _call('openAutostart');
  static Future<bool> openAppSettings() => _call('openAppSettings');

  // ---- the widget's quick-add popup (QuickAddActivity) --------------------

  static const _quick = MethodChannel('com.dw.otda/quickadd');

  /// The project the widget was showing, or null for "all projects".
  static Future<String?> quickAddProject() async {
    try {
      final id = await _quick.invokeMethod<String>('project');
      return id == null || id.isEmpty ? null : id;
    } on Object {
      return null;
    }
  }

  /// Closes the popup window.
  static Future<void> closeQuickAdd() async {
    try {
      await _quick.invokeMethod<bool>('close');
    } on Object {
      // not running inside the popup
    }
  }

  /// The `otda://` action the CompleteActivity was started with.
  static Future<String?> completeUri() async {
    try {
      return await _complete.invokeMethod<String>('uri');
    } on Object {
      return null;
    }
  }

  /// Redraws the widget from the snapshots Dart just wrote, before the invisible
  /// activity closes. The broadcast alone can be delivered after the process dies.
  static Future<void> refreshCompleteWidget() async {
    try {
      await _complete.invokeMethod<bool>('updateWidgets');
    } on Object {
      // not running inside CompleteActivity
    }
  }

  /// Asks CompleteActivity to finish and stay out of the recents list.
  static Future<void> closeComplete() async {
    try {
      await _complete.invokeMethod<bool>('close');
    } on Object {
      // already gone
    }
  }

  // ---- the reminder drawer (ReminderSheetActivity) ------------------------

  static const _reminder = MethodChannel('com.dw.otda/reminder');

  /// The `taskId|day` of the reminder that was tapped, or null.
  static Future<String?> reminderPayload() async {
    try {
      final payload = await _reminder.invokeMethod<String>('payload');
      return payload == null || payload.isEmpty ? null : payload;
    } on Object {
      return null;
    }
  }

  /// Called when another reminder is tapped while the drawer is already open.
  static void listenReminder(void Function(String payload) onPayload) {
    _reminder.setMethodCallHandler((call) async {
      if (call.method == 'payload') {
        final payload = call.arguments as String? ?? '';
        if (payload.isNotEmpty) onPayload(payload);
      }
      return null;
    });
  }

  /// Opens the task in the app (what the drawer's open button does), then closes the drawer.
  static Future<void> openTaskInApp(String taskId, String day) async {
    try {
      await _reminder.invokeMethod<bool>('openTask', {'id': taskId, 'day': day});
    } on Object {
      // not running inside the drawer
    }
  }

  /// Closes the drawer window.
  static Future<void> closeReminder() async {
    try {
      await _reminder.invokeMethod<bool>('close');
    } on Object {
      // already gone
    }
  }

  // ---- the task sheet popup (TaskSheetActivity) ----------------------------

  static const _taskSheet = MethodChannel('com.dw.otda/tasksheet');

  /// The id of the task a widget row tap asked to open, or null.
  static Future<String?> taskSheetId() async {
    try {
      final id = await _taskSheet.invokeMethod<String>('id');
      return id == null || id.isEmpty ? null : id;
    } on Object {
      return null;
    }
  }

  /// Called when another row is tapped while the popup is already open.
  static void listenTaskSheet(void Function(String id) onTask) {
    _taskSheet.setMethodCallHandler((call) async {
      if (call.method == 'task') {
        final id = call.arguments as String? ?? '';
        if (id.isNotEmpty) onTask(id);
      }
      return null;
    });
  }

  /// Hands the task to the full app, for what the popup cannot show (an end-to-end encrypted account).
  static Future<void> openTaskSheetInApp(String taskId) async {
    try {
      await _taskSheet.invokeMethod<bool>('openInApp', {'id': taskId});
    } on Object {
      // not running inside the popup
    }
  }

  /// Closes the popup window.
  static Future<void> closeTaskSheet() async {
    try {
      await _taskSheet.invokeMethod<bool>('close');
    } on Object {
      // already gone
    }
  }
}
