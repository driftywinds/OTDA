@Tags(['integration'])
library;

// Workspaces against a real v1.5.0 server:
//
//   flutter test test/workspace_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// Create, rename, move a project in and out, add the seeded second member,
// transfer ownership, leave as the former owner, then the member deletes it.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/data/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const server = String.fromEnvironment('OT_SERVER', defaultValue: 'http://127.0.0.1:18081');
const email = String.fromEnvironment('OT_EMAIL', defaultValue: 'perf@example.com');
const password = String.fromEnvironment('OT_PASSWORD', defaultValue: 'perf-password-10k');
const memberEmail = 'member@example.com';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('workspace create/rename, project move, transfer and leave reach the server', () async {
    const workspaces = WorkspaceService();
    final owner = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final signedIn = await const AuthService().login(owner, email: email, password: password);
    expect(signedIn.signedIn, isNotNull, reason: 'owner sign-in failed');
    final me = (await owner.get('/api/v1/me') as Map<String, dynamic>)['user'] as Map<String, dynamic>;

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final created = await workspaces.create(owner, name: 'Workspace test $stamp') as Map<String, dynamic>;
    final id = created['id'].toString();
    expect(id, isNotEmpty);

    await workspaces.rename(owner, id, 'Workspace renamed $stamp');
    final view = await owner.get('/api/v1/workspaces/$id') as Map<String, dynamic>;
    expect(view['name'], 'Workspace renamed $stamp');
    expect(view['ownerId'], me['id']);

    // A project created in the workspace carries its id over the op log.
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: owner, clock: clock);
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);
    final head = await owner.post('/api/v1/sync', body: {
      'device': engine.device,
      'cursor': 0,
      'ops': const <Object>[],
      'features': const ['push_only'],
    }) as Map<String, dynamic>;
    await db.setMetaInt('sync.cursor', (head['cursor'] as num).toInt());
    await db.setMetaInt('sync.full', 1);
    await engine.open();

    final project = await repo.createProject('Workspace project $stamp', workspaceId: id);
    await engine.exchange();
    var stored = await owner.get('/api/v1/projects/${project.id}') as Map<String, dynamic>;
    expect(stored['workspace_id'], id);

    // Moving it back to the default workspace is one field write.
    await repo.setField('project', project.id, 'workspace_id', null);
    await engine.exchange();
    stored = await owner.get('/api/v1/projects/${project.id}') as Map<String, dynamic>;
    expect(stored['workspace_id'], isNull);

    // Clean the project up so the workspace can be emptied.
    await repo.trashProject(project.id);
    await engine.exchange();
    final trashed = (await repo.trashedProjects()).where((p) => p.id == project.id).single;
    await repo.purgeProject(trashed);

    // The seeded member shares projects with the owner, so this is a direct add.
    await owner.post('/api/v1/workspaces/$id/members', body: {'email': memberEmail, 'role': 'admin'});
    final withMember = await owner.get('/api/v1/workspaces/$id') as Map<String, dynamic>;
    final members = (withMember['members'] as List).cast<Map>();
    final target = members.firstWhere((m) => m['userId'] != me['id']);
    expect(members, hasLength(2));

    await workspaces.transfer(owner, id, target['userId'].toString());
    final after = await owner.get('/api/v1/workspaces/$id') as Map<String, dynamic>;
    expect(after['ownerId'], target['userId']);

    await workspaces.leave(owner, id);
    await expectLater(owner.get('/api/v1/workspaces/$id'), throwsA(isA<ApiException>()));

    // The new owner removes the empty test workspace.
    final member = ApiClient(baseUrl: Uri.parse(server), jar: CookieJar());
    final memberIn = await const AuthService().login(member, email: memberEmail, password: password);
    expect(memberIn.signedIn, isNotNull, reason: 'member sign-in failed');
    await member.delete('/api/v1/workspaces/$id');
    await expectLater(member.get('/api/v1/workspaces/$id'), throwsA(isA<ApiException>()));

    await db.close();
    owner.close();
    member.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
