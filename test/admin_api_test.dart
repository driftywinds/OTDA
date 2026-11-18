@Tags(['integration'])
library;

// The administration API against a real server: reads with a session, and one
// credential route (create + revoke an invitation) which proves the step-up path.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/admin_api.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18080');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'dev@otda.local');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'otda-test-passphrase-2026');

void main() {
  late ApiClient client;
  late AdminApi admin;

  setUp(() async {
    client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final outcome = await const AuthService().login(client, email: email, password: password);
    expect(outcome.signedIn, isNotNull, reason: 'sign-in to $server failed');
    admin = AdminApi(
      client: client,
      promptReauth: () async {
        // A session that just signed in is recent; no second confirmation needed.
        await const AuthService().reauth(client, password: password);
        return true;
      },
    );
  });

  tearDown(() => client.close());

  test('the owner can read users, storage, audit and backups', () async {
    final users = await admin.users();
    expect(users, isNotEmpty);
    expect(users.first['role'], isNotNull);

    final storage = await admin.storage();
    expect(storage['database_bytes'], isA<num>());

    final events = await admin.audit(limit: 3);
    expect(events, isA<List>());

    final backups = await admin.backups();
    expect(backups.containsKey('enabled'), isTrue);
  });

  test('creating and revoking an invitation works through the step-up path', () async {
    final address = 'otda-check-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final created = await admin.invite(email: address);
    expect(created['id'], isNotNull, reason: 'the server did not return the invitation');

    final list = await admin.invitations();
    expect(list.map((i) => i['email']), contains(address));

    await admin.revokeInvitation(created['id'].toString());
    // Revoking is a status change, not a delete: the row stays, marked revoked.
    final after = await admin.invitations();
    final revoked = after.firstWhere((i) => i['id'] == created['id']);
    expect(revoked['status'], 'revoked');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
