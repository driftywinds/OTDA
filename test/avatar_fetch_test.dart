// The picture endpoint answers with bytes, and a 404 means "this account has no
// picture", not an error the caller should swallow everything of.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/api/cookie_jar.dart';

ApiClient clientReturning(http.Response response, {void Function(http.Request)? seen}) {
  final mock = MockClient((request) async {
    seen?.call(request);
    return response;
  });
  return ApiClient(
    baseUrl: Uri.parse('https://todo.example.com'),
    jar: CookieJar(),
    httpClient: mock,
  );
}

void main() {
  test('a picture comes back as bytes, with the path and query asked for', () async {
    final seen = <String>[];
    final client = clientReturning(
      http.Response.bytes(Uint8List.fromList([1, 2, 3, 4]), 200, headers: {'content-type': 'image/jpeg'}),
      seen: (request) => seen.add(request.url.toString()),
    );
    final bytes = await client.getBytes('/api/v1/users/abc/avatar?v=3');
    expect(bytes, [1, 2, 3, 4]);
    expect(seen.single, 'https://todo.example.com/api/v1/users/abc/avatar?v=3');
  });

  test('a missing picture is a 404, not a crash', () async {
    final client = clientReturning(
      http.Response('{"error":{"code":"not_found","message":"no avatar"}}', 404),
    );
    expect(
      () => client.getBytes('/api/v1/users/abc/avatar'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
    );
  });
}
