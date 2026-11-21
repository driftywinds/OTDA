import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/invitation_service.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/workspace_service.dart';

void main() {
  test('an invitation addressed to me carries its target, role and inviter', () {
    final invitation = MemberInvitation.fromJson({
      'id': 'i1',
      'kind': 'workspace',
      'targetId': 'w1',
      'targetName': 'Household',
      'role': 'admin',
      'inviterId': 'u1',
      'inviterName': 'Ada',
      'createdAt': 1000,
      'expiresAt': 2000,
    });
    expect(invitation.kindLabel, 'Workspace');
    expect(invitation.isProject, isFalse);
    expect(invitation.targetName, 'Household');
    expect(invitation.role, 'admin');
    expect(invitation.inviterName, 'Ada');

    final pending = PendingMember.fromJson({
      'id': 'i2',
      'email': 'grace@example.com',
      'role': 'viewer',
      'invitedBy': 'u1',
      'expiresAt': 3000,
    });
    expect(pending.email, 'grace@example.com');
    expect(pending.role, 'viewer');
  });

  test('listing, accepting, declining and revoking use the documented paths', () async {
    final calls = <String>[];
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/api/v1/me/member-invitations') {
          return http.Response(
            '{"invitations":[{"id":"i1","kind":"project","targetId":"p1",'
            '"targetName":"Garden","role":"editor","inviterName":"Ada",'
            '"createdAt":1,"expiresAt":2}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path.endsWith('/accept')) {
          return http.Response('{"kind":"project","targetId":"p1","role":"editor"}', 200);
        }
        return http.Response('', 204);
      }),
    );
    const service = InvitationService();

    final list = await service.list(client);
    expect(list.single.targetName, 'Garden');
    await service.accept(client, 'i1');
    await service.decline(client, 'i1');
    await service.cancelProject(client, 'p1', 'i1');
    await service.cancelWorkspace(client, 'w1', 'i2');

    expect(calls, [
      'GET /api/v1/me/member-invitations',
      'POST /api/v1/me/member-invitations/i1/accept',
      'POST /api/v1/me/member-invitations/i1/decline',
      'DELETE /api/v1/projects/p1/member-invitations/i1',
      'DELETE /api/v1/workspaces/w1/member-invitations/i2',
    ]);
  });

  test('a workspace invitation sends email and role, and pending is typed', () async {
    late Map<String, dynamic> sent;
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/workspaces/w1/members');
        sent = {
          'email': 'grace@example.com',
          'role': 'admin',
        };
        return http.Response('', 201);
      }),
    );
    await const WorkspaceService().addMember(client, 'w1', email: ' grace@example.com ', role: 'admin');
    expect(sent['email'], 'grace@example.com');
    expect(sent['role'], 'admin');

    final pending = WorkspaceService.pendingOf({
      'pending': [
        {'id': 'i1', 'email': 'grace@example.com', 'role': 'admin', 'expiresAt': 9},
      ],
    });
    expect(pending.single.email, 'grace@example.com');
  });
}
