import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/cookie_jar.dart';

/// How the app talks to the server.
enum AuthMethod {
  /// Email + password, kept as a session cookie. Primary.
  session,

  /// A pasted API token (`ot_…`). Secondary.
  token,
}

/// What the app remembers about a signed-in server between launches.
///
/// Lives in the platform keystore, never in shared preferences: it holds a
/// live session cookie or an API token.
class StoredAccount {
  StoredAccount({
    required this.serverUrl,
    required this.jar,
    required this.method,
    this.token,
    this.userId = '',
    this.userEmail = '',
    this.userName = '',
    this.userRole = '',
  });

  final String serverUrl;
  final CookieJar jar;
  final AuthMethod method;
  final String? token;
  final String userId;
  final String userEmail;
  final String userName;
  final String userRole;

  String get displayName => userName.isNotEmpty ? userName : userEmail;

  StoredAccount copyWith({String? userId, String? userEmail, String? userName, String? userRole}) =>
      StoredAccount(
        serverUrl: serverUrl,
        jar: jar,
        method: method,
        token: token,
        userId: userId ?? this.userId,
        userEmail: userEmail ?? this.userEmail,
        userName: userName ?? this.userName,
        userRole: userRole ?? this.userRole,
      );
}

class SessionStore {
  SessionStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'otda.account.v1';
  final FlutterSecureStorage _storage;

  Future<StoredAccount?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final method = map['method'] == 'token' ? AuthMethod.token : AuthMethod.session;
      return StoredAccount(
        serverUrl: map['serverUrl'] as String,
        jar: CookieJar.fromJson(map['cookies'] as String?),
        method: method,
        token: map['token'] as String?,
        userId: map['userId'] as String? ?? '',
        userEmail: map['userEmail'] as String? ?? '',
        userName: map['userName'] as String? ?? '',
        userRole: map['userRole'] as String? ?? '',
      );
    } on FormatException {
      return null; // an unreadable record is the same as signed out
    }
  }

  Future<void> write(StoredAccount account) => _storage.write(
        key: _key,
        value: jsonEncode({
          'serverUrl': account.serverUrl,
          'cookies': account.jar.toJson(),
          'method': account.method.name,
          'token': account.token,
          'userId': account.userId,
          'userEmail': account.userEmail,
          'userName': account.userName,
          'userRole': account.userRole,
        }),
      );

  Future<void> clear() => _storage.delete(key: _key);
}
