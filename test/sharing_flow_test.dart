@Tags(['integration'])
library;

// Project sharing against a real v1.5.0 server:
//
//   flutter test test/sharing_flow_test.dart \
//     --dart-define=OT_SERVER=http://127.0.0.1:18081
//
// Add the seeded second member, change the role, remove them again, and read
// the member view the screen uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/auth/auth_service.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sharing_service.dart';
import 'package:otda/src/data/sync_engine.dart';
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

  test('a project can be shared, re-roled and unshared', () async {
    const sharing = SharingService();
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

    final project = await repo.createProject('Sharing test ${DateTime.now().microsecondsSinceEpoch}');
    await engine.exchange();

    var raw = await sharing.members(client, project.id);
    var view = ProjectMembership(raw);
    expect(view.role, 'owner');
    expect(view.isShared, isFalse);
    expect(view.members, hasLength(1));

    await sharing.add(client, project.id, email: memberEmail, role: 'editor');
    raw = await sharing.members(client, project.id);
    view = ProjectMembership(raw);
    expect(view.isShared, isTrue);
    final guest = view.members.firstWhere((m) => m.email == memberEmail);
    expect(guest.role, 'editor');

    await sharing.setRole(client, project.id, guest.userId, 'viewer');
    view = ProjectMembership(await sharing.members(client, project.id));
    expect(view.members.firstWhere((m) => m.userId == guest.userId).role, 'viewer');

    await sharing.remove(client, project.id, guest.userId);
    view = ProjectMembership(await sharing.members(client, project.id));
    expect(view.isShared, isFalse);
    expect(view.members, hasLength(1));

    // Leave the fixture as it was.
    await repo.trashProject(project.id);
    await engine.exchange();
    final trashed = (await repo.trashedProjects()).where((p) => p.id == project.id).single;
    await repo.purgeProject(trashed);

    await db.close();
    client.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
