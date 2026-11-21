import '../api/api_client.dart';
import '../data/models.dart';

/// The invitation routes: what is waiting for me, and cancelling an invitation
/// sent from a project or workspace.
class InvitationService {
  const InvitationService();

  Future<List<MemberInvitation>> list(ApiClient client) async {
    final json = await client.get('/api/v1/me/member-invitations') as Map<String, dynamic>;
    return [
      for (final raw in (json['invitations'] as List?) ?? const [])
        if (raw is Map) MemberInvitation.fromJson(raw.cast<String, dynamic>()),
    ];
  }

  Future<void> accept(ApiClient client, String id) =>
      client.post('/api/v1/me/member-invitations/${Uri.encodeComponent(id)}/accept');

  Future<void> decline(ApiClient client, String id) =>
      client.post('/api/v1/me/member-invitations/${Uri.encodeComponent(id)}/decline');

  Future<void> cancelProject(ApiClient client, String projectId, String invitationId) => client.delete(
        '/api/v1/projects/${Uri.encodeComponent(projectId)}/member-invitations/'
        '${Uri.encodeComponent(invitationId)}',
      );

  Future<void> cancelWorkspace(ApiClient client, String workspaceId, String invitationId) => client.delete(
        '/api/v1/workspaces/${Uri.encodeComponent(workspaceId)}/member-invitations/'
        '${Uri.encodeComponent(invitationId)}',
      );
}
