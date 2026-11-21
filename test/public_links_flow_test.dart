@Tags(['integration'])
library;

// Public links and task pages against a real v1.5.0 server:
//
//   flutter test test/public_links_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/public_links_service.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18081');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'perf@example.com');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'perf-password-10k');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('a project link and a task page open and then stop opening', () async {
    const service = PublicLinksService();
    final client = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final signedIn = await const AuthService().login(client, email: email, password: password);
    expect(signedIn.signedIn, isNotNull, reason: 'sign-in failed');

    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    final head = await client.post('/api/v1/sync', body: {
      'device': engine.device,
      'cursor': 0,
      'ops': const <Object>[],
      'features': const ['push_only'],
    }) as Map<String, dynamic>;
    await db.setMetaInt('sync.cursor', (head['cursor'] as num).toInt());
    await db.setMetaInt('sync.full', 1);
    await engine.open();

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final project = await repo.createProject('Public test $stamp', color: '#3b82f6');
    final task = await repo.createTask('Open the page $stamp', projectId: project.id);
    await engine.exchange();

    final link = await service.create(client, project.id, rights: 'view', layout: 'list', name: 'Page test');
    expect(link.link, isNotNull);
    final publicPath = Uri.parse(link.link!).path;
    // /public/<slug>-otl_… is the page; the API takes just the otl_ secret.
    final token = RegExp(r'(otl_[A-Za-z0-9_-]+)').firstMatch(publicPath)?.group(1);
    expect(token, isNotNull);
    final publicBody = await client.get('/api/v1/public/$token');
    expect(publicBody, isA<Map>());
    expect((publicBody as Map).isNotEmpty, isTrue);

    await service.revoke(client, project.id, link.id);
    await expectLater(client.get('/api/v1/public/$token'), throwsA(isA<ApiException>()));

    final page = await service.publishTaskPage(client, task.id, rights: 'view');
    expect(page.link, isNotNull);
    final secret = Uri.parse(page.link!).pathSegments[1];
    final pageBody = await client.get('/api/v1/pages/$secret') as Map<String, dynamic>;
    expect(pageBody.toString(), contains('Open the page $stamp'));

    await service.revokeTaskPage(client, task.id);
    expect(await service.taskPage(client, task.id), isNull);

    // Clean up: trash the project (its task goes with it) and purge it.
    await repo.trashProject(project.id);
    await engine.exchange();
    final trashed = (await repo.trashedProjects()).where((p) => p.id == project.id).single;
    await repo.purgeProject(trashed);

    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
