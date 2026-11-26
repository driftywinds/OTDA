import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'api/api_client.dart';
import 'api/api_exception.dart';
import 'api/cookie_jar.dart';
import 'auth/auth_service.dart';
import 'auth/mfa_service.dart';
import 'auth/session_store.dart';
import 'data/clock.dart';
import 'data/db.dart';
import 'data/failure_meter.dart';
import 'data/instance_theme.dart';
import 'data/server_history.dart';
import 'data/repo.dart';
import 'e2ee/session.dart';
import 'reminders/service.dart';
import 'data/sync_engine.dart';
import 'util/log.dart';

/// What the first copy of the account is doing. The home screen is only shown
/// once a full pull has reached the server's head and the outbox is empty.
enum SyncGate { syncing, ready, failed, locked }

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

  /// The first-copy gate, and how far it has got.
  SyncGate _gate = SyncGate.syncing;
  SyncProgress? _gateProgress;
  String? _gateError;
  DateTime? _gateStarted;
  bool _bootstrapRunning = false;

  /// Resolves when this launch's encryption record check is done, so the first
  /// pull never starts before the device knows it is allowed to store plaintext.
  Future<void> _encryptionReady = Future<void>.value();

  /// The second-factor state of the signed-in account, read once per launch and
  /// after an enrolment. A restricted session may only enrol, so the shell has
  /// to route there before opening the replica.
  MfaStatus? _mfaStatus;
  MfaStatus? get mfaStatus => _mfaStatus;
  bool get mfaEnrolmentRequired => _mfaStatus?.restricted == true;

  /// Decides when a failure is worth showing; see [FailureMeter].
  final _failures = FailureMeter();

  /// The font is a device choice, not an account one: it lives in
  /// shared_preferences so it applies before anyone signs in.
  static const _fontPref = 'ui.font';
  static const _serversPref = 'servers.recent';
  static const _themePref = 'ui.theme';
  static const _accentPref = 'ui.accent';
  static const _darkPref = 'ui.dark';
  static const _densityPref = 'ui.density';
  static const _rowDetailsPref = 'ui.row_details';
  static const _textScalePref = 'ui.text_scale';
  static const _weekStatsPref = 'ui.week_stats';

  /// The instance theme's seeds, kept so the widget popup (which has no network
  /// and no session) can wear the same palette as the app.
  static const _instanceSeedsPref = 'ui.instance_seeds';

  /// system, light or dark.
  String _themeChoice = 'dark';

  /// The dark palette: `dark` or `amoled`, chosen independently of the mode.
  String _darkStyle = 'amoled';

  /// comfortable or compact.
  String _density = 'comfortable';

  /// all, dates or minimal: how much of a task row the list shows.
  String _rowDetails = 'all';

  /// App text size, 0.8–1.4. Separate from the widget's own text size.
  double _textScale = 1;

  /// The weekly progress card on Today is off by default; Stats is always in the
  /// sidebar and opening it has no cost to the Today layout.
  bool _showWeekStats = false;

  /// The accent the person picked, `#rrggbb`, or null to follow the instance.
  String? _accentHex;

  /// The instance theme's seeds for each side, when its default is an
  /// `instance:` theme. The app uses these only while no accent is chosen.
  Map<String, dynamic>? _instanceLightSeeds;
  Map<String, dynamic>? _instanceDarkSeeds;

  String get themeChoice => _themeChoice;
  ThemeMode get themeMode => switch (_themeChoice) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  String get darkStyle => _darkStyle;
  bool get amoled => _darkStyle == 'amoled';
  String get density => _density;
  bool get compact => _density == 'compact';
  String get rowDetails => _rowDetails;
  double get textScale => _textScale;
  bool get showWeekStats => _showWeekStats;
  String? get accentHex => _accentHex;
  Map<String, dynamic>? get instanceLightSeeds => _instanceLightSeeds;
  Map<String, dynamic>? get instanceDarkSeeds => _instanceDarkSeeds;

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
    if (_gate != SyncGate.ready) {
      // The first copy was waiting for the key: run it now.
      await _runBootstrap();
      return;
    }
    await syncNow();
    unawaited(afterDataChanged());
  }
  StoredAccount? get account => _account;
  ServerInfo? get server => _server;
  Repo? get repo => _repo;
  SyncEngine? get engine => _engine;
  bool get isSignedIn => _client != null && _account != null;
  bool get isRestoring => _restoring;
  String? get syncError => _syncError;
  DateTime? get lastSync => _lastSync;
  bool get isSyncing => _engine?.isRunning ?? false;
  int get pending => _engine?.pending ?? 0;

  /// The first-copy gate. `isReady` is the one thing the shell asks: until it
  /// is true the replica is incomplete and no task screen is shown.
  SyncGate get gate => _gate;
  bool get isReady => _repo != null && _gate == SyncGate.ready;
  SyncProgress? get gateProgress => _gateProgress;
  String? get gateError => _gateError;
  DateTime? get gateStarted => _gateStarted;

  /// Called by the gate's Retry button. Keeps the cursor, so it resumes.
  Future<void> retryGate() async {
    if (_engine == null) return;
    _failures.reset();
    await _runBootstrap();
  }

  /// Reads the account's second-factor state. A server that predates the route
  /// answers 404 and is treated as having none.
  Future<void> refreshMfaStatus() async {
    final client = _client;
    if (client == null) return;
    try {
      _mfaStatus = await const MfaService().status(client);
    } on ApiException catch (e) {
      if (e.status == 404) _mfaStatus = MfaStatus.off;
    } on Object {
      // Offline: keep what we know and let sync report the real state.
    }
    notifyListeners();
  }

  /// Re-confirms identity for the server's step-up routes (second factor,
  /// tokens, passkeys, secret-holding settings). A session cookie is required;
  /// an API token cannot step up.
  Future<void> reauth({String? password, String? code}) async {
    final client = _client;
    if (client == null) throw const ApiException(0, 'not_signed_in', 'sign in first');
    await _auth.reauth(client, password: password, code: code);
  }

  /// Called after the restricted session confirmed an enrolment: the replica can
  /// now open and the first copy begins.
  Future<void> finishMfaEnrolment() async {
    await refreshMfaStatus();
    if (_mfaStatus?.restricted == true) return; // still required: stay here
    await _openReplica();
    notifyListeners();
  }

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
      _themeChoice = prefs.getString(_themePref) ?? 'dark';
      // `amoled` used to be a value of ui.theme; it is now a separate dark style.
      if (_themeChoice == 'amoled') {
        _themeChoice = 'dark';
        _darkStyle = 'amoled';
      } else {
        _darkStyle = prefs.getString(_darkPref) ?? 'amoled';
      }
      _density = prefs.getString(_densityPref) ?? 'comfortable';
      _textScale = (prefs.getDouble(_textScalePref) ?? 1).clamp(0.8, 1.4).toDouble();
      _rowDetails = prefs.getString(_rowDetailsPref) ?? 'all';
      _showWeekStats = prefs.getBool(_weekStatsPref) ?? false;
      final accent = prefs.getString(_accentPref) ?? '';
      _accentHex = accent.isEmpty ? null : accent;
      _readInstanceSeeds(prefs.getString(_instanceSeedsPref));
    } on Object {
      _useAllo = true; // a missing store keeps the default look
    }
    notifyListeners();
  }

  void _readInstanceSeeds(String? stored) {
    if (stored == null || stored.isEmpty) return;
    try {
      final json = jsonDecode(stored);
      if (json is! Map) return;
      final light = json['light'];
      final dark = json['dark'];
      if (_instanceLightSeeds == null && light is Map) {
        _instanceLightSeeds = Map<String, dynamic>.from(light);
      }
      if (_instanceDarkSeeds == null && dark is Map) {
        _instanceDarkSeeds = Map<String, dynamic>.from(dark);
      }
    } on Object {
      // a damaged copy is only a missing palette
    }
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
    await _setPref(_themePref, choice);
  }

  /// `dark` or `amoled`, independent of whether the app is in light or dark.
  Future<void> setDarkStyle(String style) async {
    _darkStyle = style;
    notifyListeners();
    await _setPref(_darkPref, style);
  }

  Future<void> setDensity(String value) async {
    _density = value;
    notifyListeners();
    await _setPref(_densityPref, value);
  }

  /// App text size, clamped to the range the settings slider offers.
  Future<void> setTextScale(double value) async {
    _textScale = value.clamp(0.8, 1.4).toDouble();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_textScalePref, _textScale);
    } on Object {
      // the choice stays in memory for this run
    }
  }

  Future<void> setRowDetails(String value) async {
    _rowDetails = value;
    notifyListeners();
    await _setPref(_rowDetailsPref, value);
  }

  Future<void> setShowWeekStats(bool value) async {
    _showWeekStats = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_weekStatsPref, value);
    } on Object {
      // the choice stays in memory for this run
    }
  }

  /// The accent colour (`#rrggbb`), or null to follow the instance default.
  Future<void> setAccent(String? hex) async {
    _accentHex = hex;
    notifyListeners();
    await _setPref(_accentPref, hex ?? '');
  }

  Future<void> _setPref(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } on Object {
      // the choice stays in memory for this run
    }
  }

  /// Reads the instance theme and keeps the seeds of its default light/dark
  /// theme. Only `instance:<id>` defaults are used; a built-in default keeps
  /// the app's own palette, which is the same OpenTodo look.
  Future<void> loadInstanceTheme() async {
    final client = _client;
    if (client == null) return;
    try {
      final json = await client.get('/api/v1/themes/instance') as Map<String, dynamic>;
      final seeds = instanceThemeSeeds(json);
      _instanceLightSeeds = seeds.light;
      _instanceDarkSeeds = seeds.dark;
      notifyListeners();
      await _setPref(
        _instanceSeedsPref,
        jsonEncode({'light': seeds.light, 'dark': seeds.dark}),
      );
    } on Object {
      // Older servers, offline, or no instance theme: keep the app's palette.
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
      // A policy-restricted session may only enrol; opening a replica would just
      // collect 403s, so the shell routes to the enrolment screen instead.
      await refreshMfaStatus();
      if (mfaEnrolmentRequired) return;
      // Before the replica opens: a pull that runs while this device still thinks
      // the account is unencrypted stores ciphertext in the replica. The record is
      // cached after the first read, so on later launches this is a local check.
      _encryptionReady = loadEncryption();
      await _encryptionReady;
      await _openReplica();
      unawaited(loadInstanceTheme());
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
    _account = account;
    // After the account is set: _loadAvatar reads it for the user id, and firing it
    // one line early made it return on every launch, so no picture ever loaded.
    unawaited(_loadAvatar());
    otdaLog('auth: account stored, reading the server');
    _server = await _auth.health(client);
    otdaLog('auth: server ${_server?.version}, reading the second factor');
    await refreshMfaStatus();
    if (mfaEnrolmentRequired) {
      otdaLog('auth: the server requires two-factor enrolment before anything else');
      notifyListeners();
      return;
    }
    otdaLog('auth: reading the key record');
    // Before the replica opens and syncs: an account that is encrypted asks for the
    // passphrase now, and an ordinary account answers 404 and carries on unchanged.
    _encryptionReady = loadEncryption();
    await _encryptionReady;
    otdaLog('auth: encrypted=${E2eeSession.instance.enabled} unlocked=${E2eeSession.instance.unlocked}');
    await _openReplica();
    // The instance theme is decoration: it never delays opening the app.
    unawaited(loadInstanceTheme());
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
    // A replica that has never completed a first copy is not usable: the gate
    // walks the whole log before the shell opens. Otherwise this is a normal
    // launch and the sync loop starts immediately.
    if (engine.fullSyncDone) {
      _gate = SyncGate.ready;
      _startSyncLoop();
      notifyListeners();
    } else {
      _gate = SyncGate.syncing;
      _gateStarted = DateTime.now();
      _gateError = null;
      _gateProgress = null;
      otdaLog('replica: first copy (gated)');
      notifyListeners();
      unawaited(_runBootstrap());
    }
  }

  /// Starts the steady-state timer, the live channel and the first background
  /// exchange. Only called once the replica holds the whole account.
  void _startSyncLoop() {
    final engine = _engine;
    if (engine == null) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _syncQuietly());
    unawaited(engine.startLive());
    unawaited(afterDataChanged());
    otdaLog('replica: sync loop started');
  }

  /// The first copy: pull the whole log, with progress, before anything is shown.
  ///
  /// The cursor is stored page by page, so a kill, a lost connection or the
  /// phone sleeping resumes where it stopped instead of starting over. The gate
  /// only opens when the engine says the pull reached the head and the outbox is
  /// empty; a partial replica never reaches the task list.
  Future<void> _runBootstrap() async {
    final engine = _engine;
    if (engine == null || _bootstrapRunning) return;
    _bootstrapRunning = true;
    _gate = SyncGate.syncing;
    _gateError = null;
    _gateProgress = null;
    _gateStarted ??= DateTime.now();
    notifyListeners();
    try {
      await _encryptionReady;
      if (E2eeSession.instance.enabled && !E2eeSession.instance.unlocked) {
        e2eeLocked.value = true;
        _gate = SyncGate.locked;
        return;
      }
      otdaLog('replica: first copy starting at cursor ${engine.cursorForTest}');
      final result = await engine.exchange(fullSync: true, onProgress: (progress) {
        _gateProgress = progress;
        notifyListeners();
      });
      if (!engine.fullSyncDone) {
        throw const ApiException(0, 'sync_incomplete', 'the first sync did not reach the end');
      }
      _gate = SyncGate.ready;
      _lastSync = DateTime.now();
      _syncError = null;
      _failures.reset();
      otdaLog('replica: first copy done: ${result.pulled} op(s) in ${result.pages} page(s), '
          '${DateTime.now().difference(_gateStarted ?? DateTime.now()).inMilliseconds} ms');
      _startSyncLoop();
    } on E2eeLockedException {
      _gate = SyncGate.locked;
      e2eeLocked.value = true;
    } on ApiException catch (e) {
      otdaLog('replica: first copy failed: $e');
      if (e.isUnauthenticated) {
        await signOut();
        return;
      }
      if (e.code == 'mfa_enrolment_required') {
        // The policy turned on while this device was signed out, or the status
        // read was skipped offline. The shell routes to enrolment.
        _mfaStatus = const MfaStatus(
          enrolled: false,
          recoveryCodesRemaining: 0,
          policy: 'all',
          required: true,
          restricted: true,
        );
        notifyListeners();
        return;
      }
      _recordFailure(e);
      _gateError = _gateMessage(e);
      _gate = SyncGate.failed;
    } on Object catch (e) {
      otdaLog('replica: first copy failed: $e');
      _gateError = 'The first sync stopped unexpectedly. Try again.';
      _gate = SyncGate.failed;
    } finally {
      _bootstrapRunning = false;
      notifyListeners();
    }
  }

  /// A failure sentence for the gate, where there is no status line to explain
  /// a raw socket error.
  String _gateMessage(ApiException e) => switch (e.code) {
        'network' || 'timeout' =>
          'Could not reach the server. Check your connection, then try again.',
        'mfa_enrolment_required' =>
          'This server requires two-factor authentication. Set it up in Settings first.',
        'reauth_required' => 'Confirm your password to continue.',
        'invalid_credentials' => 'The server did not accept this session. Sign in again.',
        _ => e.message.isEmpty ? 'The server could not finish the first sync.' : e.message,
      };

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
    // The first copy belongs to the gate; a timer or a wake-up must not race it.
    if (_gate != SyncGate.ready) return null;
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
    await E2eeSession.instance.forget();
    await _db?.close();
    client?.close();
    _client = null;
    _account = null;
    _server = null;
    _db = null;
    _engine = null;
    _repo = null;
    _syncError = null;
    _mfaStatus = null;
    _instanceLightSeeds = null;
    _instanceDarkSeeds = null;
    await _setPref(_instanceSeedsPref, '');
    _gate = SyncGate.syncing;
    _gateProgress = null;
    _gateError = null;
    _gateStarted = null;
    _bootstrapRunning = false;
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
