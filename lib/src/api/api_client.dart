import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'cookie_jar.dart';

/// One OpenTodo server plus the credential used to talk to it.
///
/// Two credentials, per the chosen auth design: a session cookie (primary, what
/// a person signs in with) and a bearer token (secondary, for scripts and for
/// servers where SSO has closed password sign-in).
///
/// Cookie-authenticated writes must carry a JSON body and no `Origin` header;
/// a native client satisfies both by default, and this class always sets the
/// content type so the rule holds on every write.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.jar,
    this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final CookieJar jar;
  String? token;
  final http.Client _http;

  static const _timeout = Duration(seconds: 30);

  bool get hasSession => !jar.isEmpty;

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{'Accept': 'application/json'};
    if (json) h['Content-Type'] = 'application/json';
    final cookie = jar.header;
    if (cookie != null) h['Cookie'] = cookie;
    if (token != null && token!.isNotEmpty) h['Authorization'] = 'Bearer $token';
    return h;
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final clean = path.startsWith('/') ? path.substring(1) : path;
    final uri = baseUrl.resolve(clean);
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      for (final e in query.entries)
        if (e.value != null) e.key: e.value.toString(),
    });
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      send('GET', path, query: query);

  Future<dynamic> post(String path,
          {Object? body, Map<String, dynamic>? query, String? idempotencyKey}) =>
      send('POST', path, body: body, query: query, idempotencyKey: idempotencyKey);

  Future<dynamic> patch(String path, {Object? body}) =>
      send('PATCH', path, body: body);

  Future<dynamic> put(String path, {Object? body}) =>
      send('PUT', path, body: body);

  Future<dynamic> delete(String path) => send('DELETE', path);

  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? idempotencyKey,
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = http.Request(method, _uri(path, query))
      ..headers.addAll({..._headers(json: body != null), ...extraHeaders})
      // A redirect could carry the credential to another host.
      ..followRedirects = false;
    if (body != null) request.body = jsonEncode(body);

    final http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request).timeout(_timeout);
    } on TimeoutException {
      throw ApiException(0, 'timeout', 'the server did not answer in time');
    } on http.ClientException catch (e) {
      throw ApiException(0, 'network', e.message);
    }
    final response = await http.Response.fromStream(streamed);
    jar.absorb(response.headers['set-cookie']);

    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw ApiException(response.statusCode, 'redirect',
          'unexpected redirect to ${response.headers['location'] ?? '?'}');
    }
    if (response.statusCode >= 400) {
      throw ApiException.fromBody(response.statusCode, response.body);
    }
    if (response.statusCode == 204 || response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw ApiException(response.statusCode, 'not_json',
          'the server answered with something that is not JSON');
    }
  }

  /// Opens a server-sent event stream (the sync wake-up channel).
  Future<http.StreamedResponse> openStream(String path,
      {Map<String, dynamic>? query}) async {
    final request = http.Request('GET', _uri(path, query))
      ..headers.addAll({..._headers(), 'Accept': 'text/event-stream'})
      ..followRedirects = false;
    return _http.send(request);
  }

  void close() => _http.close();
}
