import '../api/api_client.dart';

/// The workspace directory routes. Reads come from the sync exchange; these are
/// the writes: create, rename, leave and transfer.
class WorkspaceService {
  const WorkspaceService();

  Future<void> create(ApiClient client, {required String name, String? icon, String? color}) =>
      client.post('/api/v1/workspaces', body: {
        'name': name.trim(),
        'icon': ?icon,
        'color': ?color,
      });

  Future<void> rename(ApiClient client, String id, String name) =>
      client.patch('/api/v1/workspaces/${Uri.encodeComponent(id)}', body: {'name': name.trim()});

  Future<void> leave(ApiClient client, String id) =>
      client.post('/api/v1/workspaces/${Uri.encodeComponent(id)}/leave');

  Future<void> transfer(ApiClient client, String id, String userId) =>
      client.post('/api/v1/workspaces/${Uri.encodeComponent(id)}/transfer', body: {'userId': userId});
}
