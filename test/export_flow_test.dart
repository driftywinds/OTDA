@Tags(['integration'])
library;

// The export route against a real v1.5.0 server:
//
//   flutter test test/export_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// The server serves JSON and ZIP; there is no PDF format in its route table.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/export_service.dart';
import 'package:path/path.dart' as p;

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18081');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'perf@example.com');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'perf-password-10k');

void main() {
  test('JSON and ZIP exports download from the server', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');

    final dir = Directory(p.join('.tmp', 'export-flow'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final service = ExportService(directory: () async => dir);

    final json = await service.download(client, format: ExportFormat.json);
    final document = jsonDecode(await File(json.path).readAsString()) as Map<String, dynamic>;
    expect(document['format'], 'opentodo-export');
    expect(document['userId'], isNotEmpty);
    expect(document['tasks'], isA<List>());
    expect((document['tasks'] as List), isNotEmpty);
    expect(document.containsKey('encryption'), isTrue);

    final zip = await service.download(client, format: ExportFormat.zip);
    final bytes = await File(zip.path).readAsBytes();
    expect(bytes.length, greaterThan(2));
    expect(bytes[0], 0x50); // P
    expect(bytes[1], 0x4b); // K

    await dir.delete(recursive: true);
    client.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
