import 'dart:developer' as developer;

/// Logs to logcat under one tag, in release too, so a device run explains itself.
void e2eeLog(String message) => developer.log('e2ee: $message', name: 'OTDA');
