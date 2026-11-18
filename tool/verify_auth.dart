// Integration check for the auth layer against a real server.
//
//   dart run tool/verify_auth.dart [baseUrl] [email] [password]
//
// Defaults point at the local v1.5.0 server started from .tmp/server.
// Pure Dart on purpose: the auth layer must not need Flutter to be testable.
import 'dart:io';

import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';

int _failures = 0;

void check(String what, bool ok, [String detail = '']) {
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $what${detail.isEmpty ? '' : '  ($detail)'}');
  if (!ok) _failures++;
}

ApiClient _client(String base) => ApiClient(baseUrl: Uri.parse(base), jar: CookieJar());

bool _rejects(String input) {
  try {
    AuthService.parseServer(input);
    return false;
  } on ApiException {
    return true;
  }
}

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : 'http://127.0.0.1:18080';
  final email = args.length > 1 ? args[1] : 'dev@otda.local';
  final password = args.length > 2 ? args[2] : 'otda-test-passphrase-2026';
  const auth = AuthService();

  // address rules
  check('bare host becomes https', AuthService.parseServer('todo.example.com').toString() == 'https://todo.example.com');
  check('explicit local http is allowed', AuthService.parseServer('http://192.168.1.4:8080').scheme == 'http');
  check('bare local address stays https', AuthService.parseServer('192.168.1.4:8080').scheme == 'https');
  check('public http is refused', _rejects('http://todo.example.com'));
  check('empty address is refused', _rejects('   '));

  // health
  final anon = _client(base);
  final info = await auth.health(anon);
  check('health answers a version', info.version.isNotEmpty, info.version);
  check('health reports app_sign_in', info.appSignIn);

  // password sign-in → session cookie
  final client = _client(base);
  final outcome = await auth.login(client, email: email, password: password);
  final signed = outcome.signedIn;
  check('password sign-in returns a session', signed != null,
      outcome.challenge != null ? 'mfa challenge (this account has none)' : '');
  if (signed == null) return _summary();
  check('session cookie stored', client.jar.header != null, client.jar.cookies.keys.join(','));
  check('cookie is opentodo_session', client.jar.cookies.containsKey('opentodo_session'));

  // the credential is a session, not a token
  final me = await auth.me(client);
  check('server sees a session', (me['auth'] as Map?)?['method'] == 'session',
      '${(me['auth'] as Map?)?['method']}');

  // reads work with the session
  final tasks = await client.get('/api/v1/tasks') as Map<String, dynamic>;
  check('tasks readable', tasks['tasks'] is List);

  // minting a token is a credential route: works because the session is fresh
  final minted = await client.post('/api/v1/tokens', body: {'name': 'otda integration check'})
      as Map<String, dynamic>;
  final secret = minted['secret']?.toString() ?? '';
  check('fresh session can mint an API token', secret.startsWith('ot_'));

  // the secondary credential
  final tokenClient = _client(base);
  final viaToken = await auth.withToken(tokenClient, secret);
  check('token signs in', viaToken.userId.isNotEmpty, viaToken.email);
  check('server sees a token', (await auth.me(tokenClient))['auth'] is Map);
  final tokenAuth = (await auth.me(tokenClient))['auth'] as Map;
  check('token scope reported', tokenAuth['scope'] != null, '${tokenAuth['scope']}');

  // wrong password is the documented refusal
  try {
    await auth.login(_client(base), email: email, password: 'definitely-wrong');
    check('wrong password refused', false);
  } on ApiException catch (e) {
    check('wrong password refused', e.status == 401 && e.code == 'invalid_credentials', e.code);
  }

  // step-up: a fresh session confirms a password for the recent routes
  await auth.reauth(client, password: password);
  check('step-up accepted', true);

  // sign out ends the session server-side
  await auth.logout(client);
  try {
    await auth.me(client);
    check('session dead after sign-out', false);
  } on ApiException catch (e) {
    check('session dead after sign-out', e.isUnauthenticated, '${e.status} ${e.code}');
  }

  await _summary();
}

Future<void> _summary() async {
  stdout.writeln(_failures == 0 ? '\nall checks passed' : '\n$_failures check(s) failed');
  exit(_failures == 0 ? 0 : 1);
}
