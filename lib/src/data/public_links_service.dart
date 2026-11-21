import '../api/api_client.dart';
import '../api/api_exception.dart';
import 'models.dart';

/// Project public links and task pages: both publish something to a URL whose
/// secret is the credential. The server returns a link only when it is created;
/// list routes never reveal it again.
class PublicLinksService {
  const PublicLinksService();

  Future<List<PublicLink>> list(ApiClient client, String projectId) async {
    final json = await client.get('/api/v1/projects/${Uri.encodeComponent(projectId)}/public-links')
        as Map<String, dynamic>;
    return [
      for (final raw in (json['links'] as List?) ?? const [])
        if (raw is Map) PublicLink.fromJson(raw.cast<String, dynamic>()),
    ];
  }

  Future<PublicLink> create(
    ApiClient client,
    String projectId, {
    required String rights,
    required String layout,
    String name = '',
    int? expiresInDays,
  }) async {
    final json = await client.post(
      '/api/v1/projects/${Uri.encodeComponent(projectId)}/public-links',
      body: {
        'rights': rights,
        'layout': layout,
        if (name.trim().isNotEmpty) 'name': name.trim(),
        'expiresInDays': ?expiresInDays,
      },
    ) as Map<String, dynamic>;
    return PublicLink.fromJson(json);
  }

  Future<void> revoke(ApiClient client, String projectId, String linkId) => client.delete(
        '/api/v1/projects/${Uri.encodeComponent(projectId)}/public-links/${Uri.encodeComponent(linkId)}',
      );

  /// The task's page, or null when it has none. A 404 is the normal "not
  /// published" answer.
  Future<TaskPage?> taskPage(ApiClient client, String taskId) async {
    try {
      final json = await client.get('/api/v1/tasks/${Uri.encodeComponent(taskId)}/page')
          as Map<String, dynamic>;
      return TaskPage.fromJson(json);
    } on Object catch (error) {
      if (error is ApiException && error.status == 404) return null;
      rethrow;
    }
  }

  Future<TaskPage> publishTaskPage(
    ApiClient client,
    String taskId, {
    required String rights,
    String label = '',
    int? expiresInDays,
  }) async {
    final json = await client.post(
      '/api/v1/tasks/${Uri.encodeComponent(taskId)}/page',
      body: {
        'rights': rights,
        if (label.trim().isNotEmpty) 'label': label.trim(),
        'expiresInDays': ?expiresInDays,
      },
    ) as Map<String, dynamic>;
    return TaskPage.fromJson(json);
  }

  Future<void> revokeTaskPage(ApiClient client, String taskId) =>
      client.delete('/api/v1/tasks/${Uri.encodeComponent(taskId)}/page');
}
