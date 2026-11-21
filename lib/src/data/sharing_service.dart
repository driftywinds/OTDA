import '../api/api_client.dart';
import 'models.dart';

/// Project sharing routes. Membership is never an op: these calls change the
/// server's directory and wake the affected devices.
class SharingService {
  const SharingService();

  Future<Map<String, dynamic>> members(ApiClient client, String projectId) async =>
      (await client.get('/api/v1/projects/${Uri.encodeComponent(projectId)}/members') as Map)
          .cast<String, dynamic>();

  /// Adds by email. The server may add the account at once (201 with the member
  /// list) or send an invitation instead; either way the caller re-reads the
  /// member list to see what happened.
  Future<Map<String, dynamic>?> add(
    ApiClient client,
    String projectId, {
    required String email,
    required String role,
  }) async =>
      (await client.post(
        '/api/v1/projects/${Uri.encodeComponent(projectId)}/members',
        body: {'email': email.trim(), 'role': role},
      ) as Map?)
          ?.cast<String, dynamic>();

  Future<void> setRole(ApiClient client, String projectId, String userId, String role) =>
      client.patch(
        '/api/v1/projects/${Uri.encodeComponent(projectId)}/members/${Uri.encodeComponent(userId)}',
        body: {'role': role},
      );

  Future<void> remove(ApiClient client, String projectId, String userId) =>
      client.delete('/api/v1/projects/${Uri.encodeComponent(projectId)}/members/${Uri.encodeComponent(userId)}');

  Future<void> cancelInvitation(ApiClient client, String projectId, String invitationId) => client.delete(
        '/api/v1/projects/${Uri.encodeComponent(projectId)}/member-invitations/'
        '${Uri.encodeComponent(invitationId)}',
      );

  /// The `pending` list of a project, typed. The member route returns it for an
  /// owner or admin.
  static List<PendingMember> pendingOf(Map<String, dynamic> raw) => [
        for (final entry in (raw['pending'] as List?) ?? const [])
          if (entry is Map) PendingMember.fromJson(entry.cast<String, dynamic>()),
      ];
}
