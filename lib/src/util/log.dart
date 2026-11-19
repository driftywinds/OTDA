import 'dart:io';

import 'package:flutter/foundation.dart';

/// One diagnostic channel that survives this ROM's logcat: every line is appended
/// to `cache/otda-debug.log` as well as printed, and `adb shell run-as` can read it.
///
/// `dart:developer` never reached logcat and the framework's own print is filtered
/// here, which is why two rounds of device testing produced no evidence at all.
void otdaLog(String message) {
  debugPrint('OTDA: $message');
  try {
    final file = File('${Directory.systemTemp.path}/otda-debug.log');
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // Logging must never take the app down.
  }
}
