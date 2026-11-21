import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the synced workspace directory carries role, owner, members and groups', () {
    final workspace = Workspace({
      'id': 'w1',
      'name': 'Household',
      'role': 'owner',
      'ownerId': 'u1',
      'default': true,
      'members': [
        {'userId': 'u1', 'name': 'Ada', 'role': 'owner'},
        {'userId': 'u2', 'name': 'Grace', 'role': 'member'},
      ],
      'groups': [
        {
          'id': 'g1',
          'name': 'Gardeners',
          'members': ['u1', 'u2'],
        },
      ],
    });

    expect(workspace.isDefault, isTrue);
    expect(workspace.isOwner, isTrue);
    expect(workspace.memberCount, 2);
    expect(workspace.members.map((m) => '${m.name}:${m.role}'), ['Ada:owner', 'Grace:member']);
    expect(workspace.groups.single.name, 'Gardeners');
    expect(workspace.groups.single.members, ['u1', 'u2']);
  });

  test('a project created in a workspace writes workspace_id in the same batch', () async {
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(
      db: db,
      client: ApiClient(baseUrl: Uri.parse('https://test.invalid'), jar: CookieJar()),
      clock: clock,
    );
    await engine.open();
    final repo = Repo(db: db, clock: clock, engine: engine);

    final project = await repo.createProject('Garden', workspaceId: 'w2');
    expect(project.workspaceId, 'w2');
    expect((await repo.task('missing')), isNull);

    final defaultProject = await repo.createProject('Inbox-side');
    expect(defaultProject.workspaceId, isNull);

    await db.close();
  });
}
