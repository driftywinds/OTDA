import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/cookie_jar.dart';

/// What a server says about itself before anyone signs in.
class ServerInfo {
  const ServerInfo({required this.version, required this.appSignIn, required this.setupRequired, required this.signupAllowed});

  final String version;
  final bool appSignIn;
  final bool setupRequired;
  final bool signupAllowed;

  static ServerInfo fromJson(Map<String, dynamic> json) => ServerInfo(
        version: json['version']?.toString() ?? '',
        appSignIn: json['app_sign_in'] == true,
        setupRequired: json['setupRequired'] == true,
        signupAllowed: json['signupAllowed'] == true,
      );
}

/// A signed-in account plus the client that talks to its server.
class SignedIn {
  const SignedIn({required this.client, required this.user});

  final ApiClient client;
  final Map<String, dynamic> user;

  String get userId => user['id']?.toString() ?? '';
  String get email => user['email']?.toString() ?? '';
  String get name => user['name']?.toString() ?? '';
  String get role => user['role']?.toString() ?? '';
}

/// Password sign-in answered with a second factor challenge instead of a session.
class MfaChallenge {
  const MfaChallenge(this.challenge, this.expiresAt);
  final String challenge;
  final int expiresAt;
}

/// The result of a password sign-in: either a session or a challenge.
class LoginOutcome {
  const LoginOutcome.signedIn(this.signedIn) : challenge = null;
  const LoginOutcome.mfa(this.challenge) : signedIn = null;

  final SignedIn? signedIn;
  final MfaChallenge? challenge;
}

/// Sign-in, sign-out and step-up, kept free of Flutter so it can be tested
/// against a server from a plain Dart script.
class AuthService {
  const AuthService();

  /// Turns what a person typed into an origin: `todo.example.com` →
  /// `https://todo.example.com`. Plain http is accepted only for a local or
  /// private address, the same rule the official apps use.
  static Uri parseServer(String input) {
    var text = input.trim();
    if (text.isEmpty) throw const ApiException(0, 'invalid_server', 'enter your server address');
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.parse(text);
    if (uri.host.isEmpty) throw const ApiException(0, 'invalid_server', 'that is not an address');
    final local = _isLocal(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
      throw ApiException(0, 'insecure_server', 'use https:// (plain http only on a local network)');
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
  }

  static bool _isLocal(String host) {
    if (host == 'localhost' || host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.home.arpa')) {
      return true;
    }
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return false;
      octets.add(n);
    }
    return octets[0] == 127 ||
        octets[0] == 10 ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31);
  }

  /// `GET /api/v1/health`, then `/healthz` for servers older than 1.0.1.
  Future<ServerInfo> health(ApiClient client) async {
    try {
      final json = await client.get('/api/v1/health');
      return ServerInfo.fromJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      final json = await client.get('/healthz');
      return ServerInfo.fromJson(json as Map<String, dynamic>);
    }
  }

  /// Email + password. Answers a session cookie, or a second factor challenge.
  Future<LoginOutcome> login(ApiClient client, {required String email, required String password}) async {
    final json = await client.post('/api/v1/auth/login', body: {'email': email.trim(), 'password': password})
        as Map<String, dynamic>;
    if (json['mfaRequired'] == true) {
      return LoginOutcome.mfa(MfaChallenge(
        json['challenge']?.toString() ?? '',
        (json['expiresAt'] as num?)?.toInt() ?? 0,
      ));
    }
    return LoginOutcome.signedIn(SignedIn(client: client, user: _user(json)));
  }

  /// Second factor: a six-digit code, or one recovery code.
  Future<SignedIn> submitMfa(
    ApiClient client, {
    required String challenge,
    String? code,
    String? recoveryCode,
    bool remember = false,
  }) async {
    final json = await client.post('/api/v1/auth/mfa', body: {
      'challenge': challenge,
      if (code != null) 'code': code,
      if (recoveryCode != null) 'recoveryCode': recoveryCode,
      'remember': remember,
    }) as Map<String, dynamic>;
    return SignedIn(client: client, user: _user(json));
  }

  /// The secondary credential: a pasted API token, verified against `/me`.
  Future<SignedIn> withToken(ApiClient client, String token) async {
    client.token = token.trim();
    final json = await client.get('/api/v1/me') as Map<String, dynamic>;
    return SignedIn(client: client, user: (json['user'] as Map).cast<String, dynamic>());
  }

  /// Everything the app knows about the signed-in account and its credential.
  Future<Map<String, dynamic>> me(ApiClient client) async =>
      await client.get('/api/v1/me') as Map<String, dynamic>;

  /// Re-confirms the password (or a code) to unlock the step-up routes that
  /// answer 403 `reauth_required`: tokens, passkeys, user administration,
  /// secret-holding settings.
  Future<void> reauth(ApiClient client, {String? password, String? code}) async {
    await client.post('/api/v1/auth/reauth', body: {
      if (password != null) 'password': password,
      if (code != null) 'code': code,
    });
  }

  /// Ends the session server-side. A token credential has nothing to end.
  Future<void> logout(ApiClient client) async {
    try {
      await client.post('/api/v1/auth/logout');
    } on ApiException {
      // signing out locally must succeed even when the session already died
    }
  }

  static Map<String, dynamic> _user(Map<String, dynamic> json) =>
      (json['user'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// Builds a client for a server with an empty credential.
  ApiClient clientFor(Uri server, {CookieJar? jar}) =>
      ApiClient(baseUrl: server, jar: jar ?? CookieJar());
}
