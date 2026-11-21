@Tags(['integration'])
library;

// Invitations against a real v1.5.0 server:
//
//   flutter test test/invitation_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/invitation_service.dart';
import 'package:otda/src/data/workspace_service.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18081');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'perf@example.com');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'perf-password-10k');

void main() {
  test('the invitation list and a workspace round trip reach the server', () async {
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final signedIn = await const AuthService().login(client, email: email, password: password);
    expect(signedIn.signedIn, isNotNull, reason: 'sign-in failed');

    final invitations = await const InvitationService().list(client);
    expect(invitations, isA<List>());
    for (final invitation in invitations) {
      expect(invitation.id, isNotEmpty);
      expect(invitation.kind, anyOf('project', 'workspace'));
      expect(invitation.targetName, isNotEmpty);
    }

    // A workspace's GET carries the `pending` list the screen reads.
    const workspaces = WorkspaceService();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final created = await workspaces.create(client, name: 'Invite test $stamp') as Map<String, dynamic>;
    final id = created['id'].toString();
    final view = await workspaces.get(client, id);
    expect(view['name'], 'Invite test $stamp');
    expect(WorkspaceService.pendingOf(view), isEmpty);
    await client.delete('/api/v1/workspaces/$id');
    client.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
