import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'api/api_client.dart';
import 'api/api_exception.dart';
import 'api/cookie_jar.dart';
import 'auth/auth_service.dart';
import 'auth/session_store.dart';
import 'data/clock.dart';
import 'data/db.dart';
import 'data/repo.dart';
import 'data/sync_engine.dart';

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
  DateTime? _lastSync;

  ApiClient? get client => _client;
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
    await _store.write(account);
    _client = client;
    _account = account;
    _server = await _auth.health(client);
    await _openReplica();
    notifyListeners();
  }

  /// Opens this account's replica and starts the sync loop.
  Future<void> _openReplica() async {
    final account = _account;
    final client = _client;
    if (account == null || client == null) return;
    final dbDir = await databaseFactory.getDatabasesPath();
    final name = account.userId.isEmpty ? 'otda.db' : 'otda-${account.userId}.db';
    final db = await OtdaDb.open(path: p.join(dbDir, name));
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    _db = db;
    _engine = engine;
    _repo = Repo(db: db, clock: clock, engine: engine);
    engine.changes.listen((_) {
      _lastSync = engine.lastSync;
      _syncError = engine.error;
      notifyListeners();
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _syncQuietly());
    await _syncQuietly();
  }

  /// Runs an exchange and folds the outcome into the UI state.
  Future<SyncResult?> syncNow() async {
    final engine = _engine;
    if (engine == null) return null;
    notifyListeners();
    try {
      final result = await engine.exchange();
      _lastSync = DateTime.now();
      _syncError = null;
      return result;
    } on ApiException catch (e) {
      _syncError = e.message;
      if (e.isUnauthenticated) await signOut();
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
    _timer?.cancel();
    _timer = null;
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
    _db?.close();
    super.dispose();
  }
}
