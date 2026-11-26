// The composer's preview line: typing parses on the device with the app's own
// grammar and shows what was recognised, with no network involved.
//
// The save path is tested in compose_task_test.dart as a pure function: real
// SQLite inside `testWidgets`' fake-async zone turns into a harness fight, and
// the merge is the part that can actually break.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/api/api_client.dart';
import 'package:otda/src/api/cookie_jar.dart';
import 'package:otda/src/data/clock.dart';
import 'package:otda/src/data/db.dart';
import 'package:otda/src/data/models.dart';
import 'package:otda/src/data/repo.dart';
import 'package:otda/src/data/sync_engine.dart';
import 'package:otda/src/ui/new_task_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Repo> buildRepo(WidgetTester tester) async {
    late Repo repo;
    await tester.runAsync(() async {
      final db = await OtdaDb.open(path: inMemoryDatabasePath);
      final clock = await HybridClock.load(db);
      final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'), jar: CookieJar());
      final engine = SyncEngine(db: db, client: client, clock: clock);
      await engine.open();
      repo = Repo(db: db, clock: clock, engine: engine);
    });
    return repo;
  }

  /// Types a line; the debounce is a `Timer` on the fake clock, so the pump
  /// advances it and the parse runs.
  Future<void> type(WidgetTester tester, String line) async {
    await tester.enterText(find.byType(TextField).first, line);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the line under the input explains what was understood', (tester) async {
    final repo = await buildRepo(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NewTaskSheet(repo: repo, projects: const [])),
    ));

    expect(find.textContaining('Type a task'), findsOneWidget);

    await type(tester, 'call Sam tomorrow 3pm p1');

    expect(find.textContaining('No date, repeat or project understood yet'), findsNothing);
    expect(find.byType(Chip), findsNWidgets(2)); // the date and the priority
  });

  testWidgets('a line with nothing recognisable says so', (tester) async {
    final repo = await buildRepo(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NewTaskSheet(repo: repo, projects: const [])),
    ));

    await type(tester, 'something without a date');

    expect(find.textContaining('No date, repeat or project understood yet'), findsOneWidget);
  });

  testWidgets('the controls are there beside the input', (tester) async {
    final repo = await buildRepo(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NewTaskSheet(repo: repo, projects: const [])),
    ));

    // The properties are icons, named by their tooltips; the project is a chip.
    for (final label in ['Date', 'Time', 'Duration', 'Repeat', 'Priority', 'Parent']) {
      expect(find.byTooltip(label), findsOneWidget, reason: 'the $label control is missing');
    }
    expect(find.text('Inbox'), findsOneWidget);
  });

  testWidgets('the Repeat control opens the granular repeat sheet', (tester) async {
    final repo = await buildRepo(tester);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NewTaskSheet(repo: repo, projects: const [])),
    ));

    await tester.tap(find.byTooltip('Repeat'));
    await tester.pumpAndSettle();

    expect(find.text('Repeat ends'), findsOneWidget);
    expect(find.text('Reminder'), findsOneWidget);
    expect(find.text('Time'), findsWidgets);
  });

  testWidgets('a started-from-parent composer fills the parent chip and project', (tester) async {
    final repo = await buildRepo(tester);
    late Task parent;
    await tester.runAsync(() async {
      parent = await repo.createTask('Mow the lawn');
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NewTaskSheet(repo: repo, projects: const [], initialParent: parent)),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Mow the lawn'), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
  });
}
