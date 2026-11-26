import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// The result of an app-lock authentication attempt.
class AppLockResult {
  const AppLockResult({required this.ok, this.error});

  final bool ok;
  final String? error;
}

/// Gates the app UI with fingerprint/face or the device PIN. It is deliberately
/// separate from [E2eeSession]: encryption stays unlocked in the background, while
/// this only decides whether the interface may be shown.
class AppLock extends ChangeNotifier {
  AppLock._();

  static final AppLock instance = AppLock._();

  final LocalAuthentication _auth = LocalAuthentication();

  bool _enabled = false;
  bool _locked = false;
  bool _busy = false;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;
  bool get busy => _busy;

  /// Called when the preference is loaded or changed. A cold load locks the app;
  /// turning it on from inside Settings can opt out because the user just
  /// authenticated in order to enable it.
  void setEnabled(bool value, {bool lock = true}) {
    final wasEnabled = _enabled;
    _enabled = value;
    if (!value) {
      _locked = false;
    } else if (!wasEnabled && lock) {
      _locked = true;
    }
    notifyListeners();
  }

  void lockNow() {
    if (!_enabled || _busy) return;
    _locked = true;
    notifyListeners();
  }

  void unlockForSession() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }

  /// Whether the device can show any local authentication prompt, biometric or
  /// device credential.
  Future<bool> canAuthenticate() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported();
    } on Object {
      return false;
    }
  }

  Future<AppLockResult> authenticate({String reason = 'Unlock OTDA'}) async {
    if (_busy) return const AppLockResult(ok: false, error: 'Authentication is already in progress.');
    if (!await canAuthenticate()) {
      return const AppLockResult(
        ok: false,
        error: 'Set a screen lock on this device first, then try again.',
      );
    }
    _busy = true;
    notifyListeners();
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
        sensitiveTransaction: true,
      );
      if (ok) {
        _locked = false;
        notifyListeners();
      }
      return AppLockResult(ok: ok, error: ok ? null : 'Authentication was cancelled.');
    } on LocalAuthException catch (e) {
      final message = switch (e.code) {
        LocalAuthExceptionCode.biometricLockout ||
        LocalAuthExceptionCode.temporaryLockout =>
          'Too many attempts. Try again in a moment, or use your device PIN.',
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.noBiometricsEnrolled =>
          'No fingerprint or face is set up on this device. Use your device PIN, or add biometrics in system settings.',
        _ => 'Could not authenticate. Use your device PIN, pattern or passcode.',
      };
      return AppLockResult(ok: false, error: message);
    } on Object {
      return const AppLockResult(
        ok: false,
        error: 'Could not start authentication. Try again, or use your device PIN.',
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
