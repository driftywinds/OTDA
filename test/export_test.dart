import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/export_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory(p.join('.tmp', 'export-test'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ApiClient clientFor(http.Response response) => ApiClient(
        baseUrl: Uri.parse('https://test.invalid'),
        jar: CookieJar(),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/export');
          expect(request.url.queryParameters['format'], anyOf('zip', 'json'));
          return response;
        }),
      );

  test('a ZIP export is streamed into the chosen directory', () async {
    final bytes = List<int>.generate(64, (i) => i);
    final client = clientFor(http.Response.bytes(bytes, 200, headers: {'content-type': 'application/zip'}));
    final progress = <int>[];
    final file = await ExportService(directory: () async => dir).download(
      client,
      format: ExportFormat.zip,
      onProgress: (received, _) => progress.add(received),
    );

    expect(file.name, 'opentodo-export.zip');
    expect(file.mime, 'application/zip');
    expect(file.bytes, 64);
    expect(await File(file.path).readAsBytes(), bytes);
    expect(progress, isNotEmpty);
    expect(progress.last, 64);
  });

  test('cancelling stops reading before anything is written', () async {
    final client = clientFor(http.Response.bytes([1, 2, 3], 200));
    await expectLater(
      ExportService(directory: () async => dir).download(
        client,
        format: ExportFormat.json,
        isCancelled: () => true,
      ),
      throwsA(isA<ExportCancelled>()),
    );
  });

  test('a server refusal comes back as its API error', () async {
    final client = clientFor(http.Response(
      '{"error":{"code":"insufficient_scope","message":"read tokens cannot export"}}',
      403,
      headers: {'content-type': 'application/json'},
    ));
    await expectLater(
      ExportService(directory: () async => dir).download(client, format: ExportFormat.json),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'insufficient_scope')),
    );
  });
}
