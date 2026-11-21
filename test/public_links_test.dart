import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/public_links_service.dart';

void main() {
  test('a public link parses rights, layout and the one-time URL', () {
    final link = PublicLink.fromJson({
      'id': 'l1',
      'projectId': 'p1',
      'rights': 'tick',
      'name': 'Grandma',
      'layout': 'board',
      'createdByName': 'Ada',
      'expiresAt': 1234,
      'link': 'https://example.test/public/grandma-otl_abc',
    });
    expect(link.rights, 'tick');
    expect(link.layout, 'board');
    expect(link.name, 'Grandma');
    expect(link.link, isNotNull);

    final listed = PublicLink.fromJson({
      'id': 'l1',
      'projectId': 'p1',
      'rights': 'view',
      'name': null,
      'layout': 'list',
      'createdAt': 1,
      'expiresAt': null,
    });
    expect(listed.link, isNull, reason: 'the list route never repeats the secret');
    expect(listed.name, isEmpty);
  });

  test('create, list, revoke and task pages use the documented paths', () async {
    final calls = <String>[];
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/api/v1/projects/p1/public-links') {
          return http.Response('{"links":[{"id":"l1","projectId":"p1","rights":"view","layout":"list"}]}', 200);
        }
        if (request.method == 'POST' && request.url.path == '/api/v1/projects/p1/public-links') {
          expect(request.body, contains('"rights":"tick"'));
          expect(request.body, contains('"layout":"board"'));
          expect(request.body, contains('"name":"Grandma"'));
          return http.Response(
            '{"id":"l2","projectId":"p1","rights":"tick","layout":"board","name":"Grandma",'
            '"link":"https://test.invalid/public/grandma-otl_x"}',
            201,
          );
        }
        if (request.method == 'GET' && request.url.path == '/api/v1/tasks/t1/page') {
          return http.Response('{"error":{"code":"not_found","message":"task page not found"}}', 404);
        }
        if (request.method == 'POST' && request.url.path == '/api/v1/tasks/t1/page') {
          return http.Response(
            '{"id":"tp1","taskId":"t1","rights":"view","encrypted":false,'
            '"replies":0,"ticks":0,"pendingReplies":0,"link":"https://test.invalid/t/secret"}',
            201,
          );
        }
        return http.Response('', 204);
      }),
    );
    const service = PublicLinksService();

    final links = await service.list(client, 'p1');
    expect(links.single.id, 'l1');
    final created = await service.create(
      client,
      'p1',
      rights: 'tick',
      layout: 'board',
      name: ' Grandma ',
    );
    expect(created.link, 'https://test.invalid/public/grandma-otl_x');

    await service.revoke(client, 'p1', 'l1');
    expect(await service.taskPage(client, 't1'), isNull);
    final page = await service.publishTaskPage(client, 't1', rights: 'view');
    expect(page.link, 'https://test.invalid/t/secret');
    await service.revokeTaskPage(client, 't1');

    expect(calls, [
      'GET /api/v1/projects/p1/public-links',
      'POST /api/v1/projects/p1/public-links',
      'DELETE /api/v1/projects/p1/public-links/l1',
      'GET /api/v1/tasks/t1/page',
      'POST /api/v1/tasks/t1/page',
      'DELETE /api/v1/tasks/t1/page',
    ]);
  });
}
