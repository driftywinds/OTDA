import '../api/api_client.dart';
import 'models.dart';

/// The workspace directory routes. Reads come from the sync exchange; these are
/// the writes: create, rename, members, leave and transfer.
class WorkspaceService {
  const WorkspaceService();

  Future<Map<String, dynamic>> get(ApiClient client, String id) async =>
      (await client.get('/api/v1/workspaces/${Uri.encodeComponent(id)}') as Map).cast<String, dynamic>();

  Future<void> create(ApiClient client, {required String name, String? icon, String? color}) =>
      client.post('/api/v1/workspaces', body: {
        'name': name.trim(),
        'icon': ?icon,
        'color': ?color,
      });

  Future<void> rename(ApiClient client, String id, String name) =>
      client.patch('/api/v1/workspaces/${Uri.encodeComponent(id)}', body: {'name': name.trim()});

  /// Adds by email. The server may add at once or store an invitation; either
  /// way a later read of the workspace shows what happened.
  Future<void> addMember(ApiClient client, String id, {required String email, required String role}) =>
      client.post('/api/v1/workspaces/${Uri.encodeComponent(id)}/members', body: {
        'email': email.trim(),
        'role': role,
      });

  Future<void> cancelInvitation(ApiClient client, String workspaceId, String invitationId) => client.delete(
        '/api/v1/workspaces/${Uri.encodeComponent(workspaceId)}/member-invitations/'
        '${Uri.encodeComponent(invitationId)}',
      );

  /// A workspace's open invitations, from the `pending` list of its GET route.
  static List<PendingMember> pendingOf(Map<String, dynamic> raw) => [
        for (final entry in (raw['pending'] as List?) ?? const [])
          if (entry is Map) PendingMember.fromJson(entry.cast<String, dynamic>()),
      ];

  Future<void> leave(ApiClient client, String id) =>
      client.post('/api/v1/workspaces/${Uri.encodeComponent(id)}/leave');

  Future<void> transfer(ApiClient client, String id, String userId) =>
      client.post('/api/v1/workspaces/${Uri.encodeComponent(id)}/transfer', body: {'userId': userId});
}
