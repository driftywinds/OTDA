import 'dart:async';


import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'api/api_client.dart';
import 'api/api_exception.dart';
import 'api/cookie_jar.dart';
import 'auth/auth_service.dart';
import 'auth/session_store.dart';
import 'data/clock.dart';
import 'data/db.dart';
import 'data/failure_meter.dart';
import 'data/server_history.dart';
import 'data/repo.dart';
import 'e2ee/session.dart';
import 'reminders/service.dart';
import 'data/sync_engine.dart';
import 'util/log.dart';

/// The app's session: who is signed in, to which server, with which credential,
/// plus the local replica and the sync loop behind it.
class AppState extends ChangeNotifier {
  AppState({AuthService? auth, SessionStore? store})
      : _auth = auth ?? const AuthService(),
        _store = store ?? SessionStore();

  final AuthService _auth;
  final SessionStore _store;

  ApiClient? _client;
  StoredAccount? _account;
  ServerInfo? _server;
  OtdaDb? _db;
  SyncEngine? _engine;
  Repo? _repo;
  Timer? _timer;
  bool _restoring = true;
  String? _syncError;

  /// Decides when a failure is worth showing; see [FailureMeter].
  final _failures = FailureMeter();

  /// The font is a device choice, not an account one: it lives in
  /// shared_preferences so it applies before anyone signs in.
  static const _fontPref = 'ui.font';
  static const _serversPref = 'servers.recent';
  static const _themePref = 'ui.theme';

  /// system, light, dark or amoled.
  String _themeChoice = 'amoled';
  String get themeChoice => _themeChoice;
  ThemeMode get themeMode => switch (_themeChoice) {
        'light' => ThemeMode.light,
        'dark' || 'amoled' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  bool get amoled => _themeChoice == 'amoled';

  /// The signed-in account's picture, downloaded once per version. Zero versions
  /// mean the account has none, and the avatar falls back to initials.
  Uint8List? _avatarBytes;
  Uint8List? get avatarBytes => _avatarBytes;
  bool _useAllo = true;
  bool get useAllo => _useAllo;
  DateTime? _lastSync;

  ApiClient? get client => _client;

  /// True when the server's account has a key record this device cannot open: the
  /// app asks for the passphrase and syncs nothing meanwhile.
  final e2eeLocked = ValueNotifier<bool>(false);

  /// Reads the wrapped key record and keeps what this device already knows. Accounts
  /// without one are untouched: `enabled` stays false and nothing prompts.
  Future<void> loadEncryption() async {
    try {
      await E2eeSession.instance.restore();
    } on Object catch (e) {
      otdaLog('OTDA/e2ee: restore failed: $e');
    }
    final client = _client;
    if (client == null) return;
    // The record is cached when it is first read, and only changes when encryption
    // is turned on or off, so a normal launch syncs without this round trip. It was
    // holding the first exchange back for as long as the request took.
    if (E2eeSession.instance.record != null) {
      e2eeLocked.value = !E2eeSession.instance.unlocked;
      return;
    }
    try {
      await E2eeSession.instance.fetchRecord(client).timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      // Offline, or the route is missing: the cached copy decides. This must never
      // abort opening the replica, or nothing syncs at all.
      otdaLog('OTDA/e2ee: record fetch failed: $e');
    }
    e2eeLocked.value = E2eeSession.instance.enabled && !E2eeSession.instance.unlocked;
  }

  /// Called after a successful unlock: the key is in the keystore, so the next
  /// exchange decrypts and the UI can load everything the pull brings.
  Future<void> afterUnlock() async {
    e2eeLocked.value = false;
    final db = _db;
    if (db != null) {
      // What synced before this device was unlocked is ciphertext in the replica.
      await E2eeSession.instance.openLocalReplica(db);
    }
    notifyListeners();
    await syncNow();
    unawaited(afterDataChanged());
  }
  StoredAccount? get account => _account;
  ServerInfo? get server => _server;
  Repo? get repo => _repo;
  SyncEngine? get engine => _engine;
  bool get isSignedIn => _client != null && _account != null && _repo != null;
  bool get isRestoring => _restoring;
  String? get syncError => _syncError;
  DateTime? get lastSync => _lastSync;
  bool get isSyncing => _engine?.isRunning ?? false;
  int get pending => _engine?.pending ?? 0;

  /// The servers this device has signed in to, most recent first.
  Future<List<String>> recentServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_serversPref) ?? const [];
    } on Object {
      return const [];
    }
  }

  /// Keeps the address that just worked, newest first, without duplicates.
  Future<void> _rememberServer(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = rememberServer(prefs.getStringList(_serversPref) ?? const [], url);
      await prefs.setStringList(_serversPref, list);
    } on Object {
      // remembering is a convenience, never a failure
    }
  }

  /// Reads the device-only preferences. Called once at start-up.
  Future<void> loadLocalPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _useAllo = (prefs.getString(_fontPref) ?? 'allo') == 'allo';
      _themeChoice = prefs.getString(_themePref) ?? 'amoled';
    } on Object {
      _useAllo = true; // a missing store keeps the default look
    }
    notifyListeners();
  }

  /// Reads the profile's picture version and, when there is one, its bytes.
  /// A picture is decoration: failing to get it must never break signing in.
  Future<void> _loadAvatar() async {
    final client = _client;
    final account = _account;
    if (client == null || account == null) return;
    try {
      final profile = await AuthService().me(client);
      final raw = profile['avatarVersion'];
      final version = raw is num ? raw.toInt() : 0;
      final id = Uri.encodeComponent(account.userId);
      // The version is omitted when it is 0, and a server that has a picture does
      // not always report one: ask for the picture anyway and let 404 mean none.
      final suffix = version > 0 ? '?v=$version' : '';
      Uint8List? bytes;
      try {
        bytes = await client.getBytes('/api/v1/users/$id/avatar$suffix');
      } on ApiException catch (e) {
        if (e.status != 404) rethrow;
      }
      _avatarBytes = bytes;
    } on Object {
      _avatarBytes = null;
    }
    notifyListeners();
  }

  Future<void> setThemeChoice(String choice) async {
    _themeChoice = choice;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themePref, choice);
    } on Object {
      // the choice stays in memory for this run
    }
  }

  Future<void> setUseAllo(bool value) async {
    _useAllo = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_fontPref, value ? 'allo' : 'system');
    } on Object {
      // the choice stays in memory for this run
    }
  }

  /// Reloads the stored session, checks it still works, opens the replica.
  Future<void> restore() async {
    try {
      final stored = await _store.read();
      if (stored == null) return;
      final client = ApiClient(
        baseUrl: Uri.parse(stored.serverUrl),
        jar: CookieJar(stored.jar.cookies),
        token: stored.token,
      );
      try {
        final me = await _auth.me(client);
        final user = (me['user'] as Map?)?.cast<String, dynamic>() ?? const {};
        _server = await _auth.health(client);
        _account = stored.copyWith(
          userId: user['id']?.toString(),
          userEmail: user['email']?.toString(),
          userName: user['name']?.toString(),
          userRole: user['role']?.toString(),
        );
        await _store.write(_account!);
      } on ApiException catch (e) {
        if (e.isUnauthenticated) {
          await _store.clear();
          return;
        }
        // Offline: open what is already on the device and sync when it returns.
        _account = stored;
      }
      _client = client;
      await _openReplica();
      // Before anything syncs: a pull that runs while this device still thinks the
    // account is unencrypted stores ciphertext in the replica.
    // Deliberately not awaited: what this device knows about encryption must never
    // delay or block opening the replica and syncing.
    unawaited(loadEncryption());
    unawaited(afterDataChanged());
      // The picture is not needed to be online, but fetching it here means a
      // restart shows the account's face instead of initials.
      unawaited(_loadAvatar());
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  ApiClient newClient(Uri server) => ApiClient(baseUrl: server, jar: CookieJar());

  Future<ServerInfo> probe(ApiClient client) => _auth.health(client);

  Future<LoginOutcome> signInWithPassword(ApiClient client, String email, String password) async {
    final outcome = await _auth.login(client, email: email, password: password);
    if (outcome.signedIn != null) await _adopt(client, outcome.signedIn!, AuthMethod.session);
    return outcome;
  }

  Future<void> finishMfa(ApiClient client, String challenge,
      {String? code, String? recoveryCode, bool remember = false}) async {
    final signed = await _auth.submitMfa(client,
        challenge: challenge, code: code, recoveryCode: recoveryCode, remember: remember);
    await _adopt(client, signed, AuthMethod.session);
  }

  Future<void> signInWithToken(ApiClient client, String token) async {
    final signed = await _auth.withToken(client, token);
    await _adopt(client, signed, AuthMethod.token);
  }

  Future<void> _adopt(ApiClient client, SignedIn signed, AuthMethod method) async {
    final account = StoredAccount(
      serverUrl: client.baseUrl.toString(),
      jar: client.jar,
      method: method,
      token: method == AuthMethod.token ? client.token : null,
      userId: signed.userId,
      userEmail: signed.email,
      userName: signed.name,
      userRole: signed.role,
    );
    otdaLog('auth: signed in as ${signed.email} on ${client.baseUrl}');
    await _store.write(account);
    await _rememberServer(account.serverUrl);
    _client = client;
    unawaited(_loadAvatar());
    _account = account;
    otdaLog('auth: account stored, reading the server');
    _server = await _auth.health(client);
    otdaLog('auth: server ${_server?.version}, reading the key record');
    // Before the replica opens and syncs: an account that is encrypted asks for the
    // passphrase now, and an ordinary account answers 404 and carries on unchanged.
    await loadEncryption();
    otdaLog('auth: encrypted=${E2eeSession.instance.enabled} unlocked=${E2eeSession.instance.unlocked}');
    await _openReplica();
    otdaLog('auth: replica open, engine=${_engine != null}');
    notifyListeners();
  }

  /// Opens this account's replica and starts the sync loop.
  Future<void> _openReplica() async {
    final account = _account;
    final client = _client;
    if (account == null || client == null) return;
    final dbDir = await databaseFactory.getDatabasesPath();
    final name = account.userId.isEmpty ? 'otda.db' : 'otda-${account.userId}.db';
    otdaLog('replica: opening $name');
    final db = await OtdaDb.open(path: p.join(dbDir, name));
    otdaLog('replica: open');
    // Any local write (a task, a project, a setting) refreshes the widget and the
    // reminder plan, so nothing has to remember to call the refresh itself.
    db.onWrite = _scheduleAfterChange;
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    otdaLog('replica: engine open');
    _db = db;
    _engine = engine;
    _repo = Repo(db: db, clock: clock, engine: engine);
    engine.changes.listen((_) {
      _lastSync = engine.lastSync;
      // The background sync goes through here, not through syncNow, so it has to
      // follow the same wording rule or the raw socket text leaks through.
      final failure = engine.failure;
      if (failure == null) {
        _syncError = null;
        _failures.reset();
      } else if (!failure.isUnauthenticated) {
        _recordFailure(failure);
      }
      notifyListeners();
    });
    // The widget and the reminders come from what is on the device, so they are
    // written now and not only after a sync that may never succeed (offline).
    unawaited(afterDataChanged());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _syncQuietly());
    // Not awaited: the first exchange on a long history is tens of thousands of
    // ops, and login used to sit on it (the app was swiped away as hung). The UI
    // opens now and the catch-up runs behind it.
    otdaLog('replica: first exchange (background)');
    unawaited(_syncQuietly().then((_) {
      otdaLog('replica: first exchange done, error=${_syncError ?? 'none'}');
    }));
    await engine.startLive();
    otdaLog('replica: live stream started');
  }

  /// What a failed exchange is worth saying.
  ///
  /// "failed host lookup" is a developer's sentence, and a phone that has just
  /// woken up resolves nothing for a moment, so an unreachable server is only
  /// reported after it happens twice in a row and then in plain words. A server
  /// that answered and said no is reported at once, in its own words, because
  /// that one needs action.
  void _recordFailure(ApiException e) {
    _syncError = _failures.add(e);
  }

  bool _changeRunning = false;
  bool _changeAgain = false;

  /// Called after every field write. A task is several writes, so this coalesces
  /// them, but it does not wait for a timer: a push is already running or it starts
  /// now. Nothing about the widget depends on a sync.
  void _scheduleAfterChange() {
    _changeAgain = true;
    if (!_changeRunning) unawaited(_drainChanges());
  }

  Future<void> _drainChanges() async {
    _changeRunning = true;
    try {
      while (_changeAgain) {
        _changeAgain = false;
        // Let the write that triggered this finish before reading it back.
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await afterDataChanged();
      }
    } finally {
      _changeRunning = false;
    }
  }

  /// The one trigger the blueprint allows: every finished sync and every local
  /// change lands here, which re-arms reminders and refreshes the widget.
  Future<void> afterDataChanged() async {
    final repo = _repo;
    if (repo == null) return;
    // The widget goes first and on its own: it must never wait on the notification
    // permission dialog or fail because of it.
    try {
      await pushWidgetsFromRepo(repo);
    } on Object {
      // nothing to show
    }
    try {
      await ReminderService.instance.rearmFrom(repo);
      if (ReminderService.instance.lastPlan.isNotEmpty) {
        await ReminderService.instance.requestPermissionOnce();
      }
    } on Object {
      // the Notifications card in Settings shows the reason
    }
  }

  /// Runs an exchange and folds the outcome into the UI state.
  Future<SyncResult?> syncNow() async {
    otdaLog('OTDA/sync: asked (engine=${_engine != null} client=${_client != null})');
    final engine = _engine;
    if (engine == null) return null;
    // Encryption does not gate syncing: if the account turns out to be encrypted,
    // the lock flag raises the passphrase sheet, and what was pulled as ciphertext
    // is decrypted in place once the device is unlocked.
    if (E2eeSession.instance.enabled && !E2eeSession.instance.unlocked) {
      e2eeLocked.value = true;
    }
    notifyListeners();
    try {
      otdaLog('OTDA/sync: exchanging');
      final result = await engine.exchange();
      otdaLog('OTDA/sync: done applied=${result.applied} pulled=${result.pulled} pending=${result.pending} pages=${result.pages}');
      _lastSync = DateTime.now();
      _syncError = null;
      _failures.reset();
      unawaited(afterDataChanged());
      return result;
    } on E2eeLockedException {
      e2eeLocked.value = true;
      return null;
    } on ApiException catch (e) {
      otdaLog('OTDA/sync: API error $e');
      if (e.isUnauthenticated) {
        await signOut();
        return null;
      }
      _recordFailure(e);
      return null;
    } on Object catch (e) {
      // Anything else must surface: a silent failure looks like "never synced".
      otdaLog('OTDA/sync: FAILED $e');
      _recordFailure(ApiException(0, 'sync_failed', '$e'));
      return null;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _syncQuietly() async {
    try {
      await syncNow();
    } catch (_) {
      // the status line already carries the error
    }
  }

  Future<void> signOut() async {
    // Remember the address before the session that holds it goes away: losing it
    // here is what left the sign-in screen with nothing to offer.
    final server = _account?.serverUrl;
    if (server != null) await _rememberServer(server);
    _timer?.cancel();
    _timer = null;
    _engine?.stopLive();
    final client = _client;
    if (client != null) await _auth.logout(client);
    await _store.clear();
    await _db?.close();
    client?.close();
    _client = null;
    _account = null;
    _server = null;
    _db = null;
    _engine = null;
    _repo = null;
    _syncError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _engine?.stopLive();
    _db?.close();
    super.dispose();
  }
}
