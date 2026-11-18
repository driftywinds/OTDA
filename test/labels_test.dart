// Labels: a quick-add line names them, a task stores ids. Resolving by name must
// be case-insensitive and must not create a second label for the same name.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var counter = 0;

  Future<(Repo, OtdaDb, String)> buildRepo() async {
    final path = p.join(Directory.systemTemp.path, 'otda_label_${DateTime.now().microsecondsSinceEpoch}_${counter++}.db');
    final db = await OtdaDb.open(path: path);
    final clock = await HybridClock.load(db);
    final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    return (Repo(db: db, clock: clock, engine: engine), db, path);
  }

  test('a name resolves to one label, whatever the case', () async {
    final (repo, db, path) = await buildRepo();
    final first = await repo.ensureLabel('shop');
    final second = await repo.ensureLabel('Shop');
    final third = await repo.ensureLabel(' shop ');

    expect(second, first);
    expect(third, first);
    expect((await repo.labels()).length, 1);

    await db.close();
    await databaseFactory.deleteDatabase(path);
  });

  test('different names make different labels', () async {
    final (repo, db, path) = await buildRepo();
    final a = await repo.ensureLabel('home');
    final b = await repo.ensureLabel('work');
    expect(a, isNot(b));
    expect((await repo.labels()).length, 2);
    await db.close();
    await databaseFactory.deleteDatabase(path);
  });

  test('the names a quick-add line produced become ids', () async {
    final (repo, db, path) = await buildRepo();
    final ids = await repo.resolveLabelNames(['shop', {'name': 'Errand'}, '']);
    expect(ids.length, 2);
    final labels = await repo.labels();
    expect(labels.map((l) => l.name), containsAll(['shop', 'Errand']));
    await db.close();
    await databaseFactory.deleteDatabase(path);
  });
}
