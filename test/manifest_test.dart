// Guards the release build's one hard requirement: the INTERNET permission.
//
// Flutter's template puts it in the debug and profile manifests only, so a
// release APK built without it here silently cannot reach any server — which is
// exactly what happened once. Reading the manifest is enough to catch it, and it
// needs no Android toolchain.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the main manifest grants INTERNET', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest.contains('android.permission.INTERNET'),
      isTrue,
      reason: 'a release build without INTERNET cannot talk to any OpenTodo server',
    );
  });

  test('the app id matches the package name', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle.contains('applicationId = "com.dw.otda"'), isTrue);
    expect(gradle.contains('namespace = "com.dw.otda"'), isTrue);
  });
}
