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
}
