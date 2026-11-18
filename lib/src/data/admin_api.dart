import '../api/api_client.dart';
import '../api/api_exception.dart';

/// Asks the person to confirm their password (or a code) for the step-up routes.
typedef ReauthPrompt = Future<bool> Function();

/// Administration over REST: users, invitations, audit, backups.
///
/// Every mutating route here is `credential.recent` on the server, which answers
/// 403 `reauth_required` until a password or code was confirmed in the last ten
/// minutes. [_withStepUp] asks once, retries once, and leaves the refusal alone
/// if the person backs out.
class AdminApi {
  AdminApi({required this.client, required this.promptReauth});

  final ApiClient client;
  final ReauthPrompt promptReauth;

  Future<T> _withStepUp<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiException catch (e) {
      if (!e.needsReauth) rethrow;
      if (!await promptReauth()) throw const ApiException(403, 'reauth_required', 'Confirmation cancelled');
      return await action();
    }
  }

  // ---- users -------------------------------------------------------------

  Future<List<Map<String, Object?>>> users() async {
    final json = await client.get('/api/v1/users') as Map<String, dynamic>;
    return [
      for (final user in (json['users'] as List?) ?? const [])
        if (user is Map) user.cast<String, Object?>(),
    ];
  }

  Future<void> setRole(String userId, String role) => _withStepUp(
        () => client.put('/api/v1/users/$userId/role', body: {'role': role}),
      );

  Future<void> deactivate(String userId) =>
      _withStepUp(() => client.post('/api/v1/users/$userId/deactivate'));

  Future<void> reactivate(String userId) =>
      _withStepUp(() => client.post('/api/v1/users/$userId/reactivate'));

  Future<void> sendPasswordReset(String userId) =>
      _withStepUp(() => client.post('/api/v1/users/$userId/password-reset'));

  /// Ownership is not a role change: the server has its own route for it.
  Future<void> transferOwnership(String userId) =>
      _withStepUp(() => client.post('/api/v1/users/$userId/transfer-ownership'));

  // ---- invitations -------------------------------------------------------

  Future<List<Map<String, Object?>>> invitations() async {
    final json = await client.get('/api/v1/invitations') as Map<String, dynamic>;
    return [
      for (final invitation in (json['invitations'] as List?) ?? const [])
        if (invitation is Map) invitation.cast<String, Object?>(),
    ];
  }

  /// Creates an invitation. `send: false` keeps it in the app (no outgoing mail
  /// needed); the answer carries the invitation and the `link` to hand over.
  Future<Map<String, Object?>> invite({required String email, int? expiresInHours}) =>
      _withStepUp(() async {
        final json = await client.post('/api/v1/invitations', body: {
          'email': email,
          'expiresInHours': ?expiresInHours,
          'send': false,
        });
        final answer = (json as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
        final invitation = (answer['invitation'] as Map?)?.cast<String, Object?>() ?? const {};
        return {...invitation, 'link': ?answer['link']};
      });

  Future<void> revokeInvitation(String id) =>
      _withStepUp(() => client.delete('/api/v1/invitations/$id'));

  // ---- audit -------------------------------------------------------------

  Future<List<Map<String, Object?>>> audit({int limit = 25}) async {
    final json = await client.get('/api/v1/audit', query: {'limit': limit}) as Map<String, dynamic>;
    return [
      for (final event in (json['events'] as List?) ?? const [])
        if (event is Map) event.cast<String, Object?>(),
    ];
  }

  // ---- backups and storage (reads, no step-up) ----------------------------

  Future<Map<String, Object?>> backups() async =>
      (await client.get('/api/v1/backups') as Map?)?.cast<String, Object?>() ?? const {};

  Future<void> runBackup() => _withStepUp(() => client.post('/api/v1/backups/run'));

  Future<Map<String, Object?>> storage() async =>
      (await client.get('/api/v1/settings/storage') as Map?)?.cast<String, Object?>() ?? const {};
}
