// A facelift can compile and still explode at runtime: theme objects, a TabBar
// with no controller, a Drawer inside a TabBarView. These pump the pieces the
// app actually composes, in both brightnesses, and fail on any exception.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otda/src/ui/theme.dart';

Widget sheet(Brightness brightness) => MaterialApp(
      theme: buildTheme(brightness),
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            bottom: const TabBar(tabs: [Tab(text: 'You'), Tab(text: 'Server')]),
          ),
          drawer: Drawer(
            child: ListView(
              children: const [
                ListTile(leading: Icon(Icons.inbox_outlined), title: Text('Inbox')),
                Divider(),
                ListTile(title: Text('PROJECTS')),
              ],
            ),
          ),
          body: const TabBarView(children: [Text('you'), Text('server')]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: 1,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.inbox_outlined), label: 'Inbox'),
              NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), label: 'Today'),
            ],
          ),
          floatingActionButton: FloatingActionButton(onPressed: () {}, child: const Icon(Icons.add)),
        ),
      ),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('the shell chrome renders in ${brightness.name}', (tester) async {
      await tester.pumpWidget(sheet(brightness));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);

      // The drawer opens over the tabs without the two fighting.
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text('PROJECTS'), findsOneWidget);
    });
  }

  testWidgets('both themes build', (tester) async {
    expect(buildTheme(Brightness.light).colorScheme.brightness, Brightness.light);
    expect(buildTheme(Brightness.dark).colorScheme.brightness, Brightness.dark);
  });

  testWidgets('the chosen font reaches the text theme', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light, fontFamily: alloFont),
      home: Builder(builder: (context) {
        expect(Theme.of(context).textTheme.bodyMedium?.fontFamily, alloFont);
        expect(Theme.of(context).textTheme.titleLarge?.fontFamily, alloFont);
        return const SizedBox();
      }),
    ));
    // Without a family the platform face is used.
    expect(buildTheme(Brightness.light).textTheme.bodyMedium?.fontFamily, isNot(alloFont));
  });

  test('AMOLED paints the page black and the cards nearly so', () {
    final amoled = buildTheme(Brightness.dark, amoled: true);
    expect(amoled.colorScheme.page, const Color(0xFF000000));
    expect(amoled.scaffoldBackgroundColor, const Color(0xFF000000));
    // The ordinary dark theme keeps its own page colour.
    expect(buildTheme(Brightness.dark).colorScheme.page, isNot(const Color(0xFF000000)));
  });
}
