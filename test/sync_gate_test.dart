import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fake sync endpoint: [total] one-field task ops, [pageSize] per response.
class _FakeSync {
  _FakeSync({required this.total, required this.pageSize, this.failAtCall});

  final int total;
  final int pageSize;

  /// Fail the Nth request (1-based) with a 503, to exercise a lost connection.
  final int? failAtCall;
  int calls = 0;
  final List<Map<String, dynamic>> requests = [];

  int get head => total;

  http.Client client() => MockClient((request) async {
    calls++;
    if (failAtCall != null && calls == failAtCall) {
      return http.Response('offline', 503);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(body);
    final features = (body['features'] as List?) ?? const [];
    final ops = (body['ops'] as List?) ?? const [];

    if (features.contains('push_only') && ops.isEmpty) {
      return http.Response(
        jsonEncode({
          'applied': 0,
          'ops': <Object>[],
          'cursor': head,
          'hasMore': false,
          'serverTime': DateTime.now().millisecondsSinceEpoch,
          'generation': 'g1',
          'rejected': <Object>[],
          'memberships': <Object>[],
          'workspaces': <Object>[],
          'purged': <Object>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    final cursor = (body['cursor'] as num?)?.toInt() ?? 0;
    final end = (cursor + pageSize).clamp(0, total);
    final page = [
      for (var i = cursor; i < end; i++)
        {
          'id': 'op-$i',
          'entity': 'task',
          'entityId': 'task-$i',
          'field': 'title',
          'value': 'Task $i',
          'ts': 1000 + i,
          'device': 'server',
        },
    ];
    return http.Response(
      jsonEncode({
        'applied': 0,
        'ops': page,
        'cursor': end,
        'hasMore': end < total,
        'serverTime': DateTime.now().millisecondsSinceEpoch,
        'generation': 'g1',
        'rejected': <Object>[],
        'memberships': <Object>[],
        'workspaces': <Object>[],
        'purged': <Object>[],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(SyncEngine, OtdaDb, _FakeSync, ApiClient)> engineFor(
    _FakeSync fake,
  ) async {
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: fake.client(),
    );
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();
    return (engine, db, fake, client);
  }

  test(
    'fullSync pulls every page in one exchange and marks the copy complete',
    () async {
      final fake = _FakeSync(total: 25, pageSize: 5);
      final (engine, db, _, client) = await engineFor(fake);
      final progress = <SyncProgress>[];

      final result = await engine.exchange(
        fullSync: true,
        onProgress: progress.add,
      );

      expect(result.pages, 5);
      expect(result.pulled, 25);
      expect(engine.fullSyncDone, isTrue);
      expect(engine.cursorForTest, 25);
      expect(progress.last.fraction, 1.0);
      expect(progress.map((p) => p.done), orderedEquals([5, 10, 15, 20, 25]));
      // One probe, then one request per page.
      expect(fake.requests.first['features'], contains('push_only'));
      expect(fake.requests.length, 6);

      await db.close();
      client.close();
    },
  );

  test(
    'a normal exchange still stops at 20 pages; the next one resumes',
    () async {
      final fake = _FakeSync(total: 125, pageSize: 5);
      final (engine, db, _, client) = await engineFor(fake);

      final first = await engine.exchange();
      expect(first.pages, 20);
      expect(first.pulled, 100);
      expect(engine.fullSyncDone, isFalse);
      expect(engine.cursorForTest, 100);

      final second = await engine.exchange(fullSync: true);
      expect(second.pages, 5);
      expect(second.pulled, 25);
      expect(engine.fullSyncDone, isTrue);
      expect(engine.cursorForTest, 125);

      await db.close();
      client.close();
    },
  );

  test('a lost connection keeps the copy incomplete and the cursor resumable', () async {
    // Call 1 is the head probe, 2 and 3 are pages, 4 fails, leaving the cursor
    // after the second page.
    final fake = _FakeSync(total: 25, pageSize: 5, failAtCall: 4);
    final client = ApiClient(
      baseUrl: Uri.parse('https://test.invalid'),
      jar: CookieJar(),
      httpClient: fake.client(),
    );
    final db = await OtdaDb.open(path: inMemoryDatabasePath);
    final clock = await HybridClock.load(db);
    final engine = SyncEngine(db: db, client: client, clock: clock);
    await engine.open();

    await expectLater(
      engine.exchange(fullSync: true),
      throwsA(isA<Exception>()),
    );
    expect(engine.fullSyncDone, isFalse);
    expect(engine.cursorForTest, 10);

    // The retry reads the head again and only the rest.
    final resumed = await engine.exchange(fullSync: true);
    expect(resumed.pulled, 15);
    expect(resumed.pages, 3);
    expect(engine.fullSyncDone, isTrue);
    expect(engine.cursorForTest, 25);

    await db.close();
    client.close();
  });
}
