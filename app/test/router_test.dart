/// Where everything is (router.dart): an address opens its page over the
/// home screen, back comes home, an older room link and a game reached by
/// its address alone are sent where they belong, and the session's own
/// parameters stay in the address wherever it goes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_hearts/about_page.dart';
import 'package:open_hearts/net/buying.dart';
import 'package:open_hearts/pages.dart';
import 'package:open_hearts/router.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';

/// The app's routes from [location], with a stand-in home screen that
/// says which room it is in.
Future<GoRouter> pumpAt(WidgetTester tester, String location, {String boot = 'https://openhearts.game/play/'}) async {
  final router = appRouter(
    boot: Uri.parse(boot),
    initialLocation: location,
    home: (_, room) => Scaffold(body: Text('home ${room ?? '-'}')),
  );
  await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

/// What the address bar says.
String where(GoRouter router) => router.routeInformationParser.restoreRouteInformation(router.routerDelegate.currentConfiguration)!.uri.toString();

void main() {
  testWidgets('a page\'s address opens it over the home screen, and back comes home', (tester) async {
    final router = await pumpAt(tester, '/about');
    expect(find.byType(AboutPage), findsOneWidget);
    expect(where(router), '/about');
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsNothing);
    expect(find.text('home -'), findsOneWidget);
    expect(where(router), '/');
  });

  testWidgets('a room is the home screen, in that room; an older link and a bad code are sent where they belong', (tester) async {
    var router = await pumpAt(tester, '/room/KP4T9MXR');
    expect(find.text('home KP4T9MXR'), findsOneWidget);
    router = await pumpAt(tester, '/?room=KP4T9MXR');
    expect(where(router), '/room/KP4T9MXR', reason: 'a link from before rooms had addresses');
    expect(find.text('home KP4T9MXR'), findsOneWidget);
    router = await pumpAt(tester, '/room/not-a-code');
    expect(where(router), '/');
  });

  testWidgets('a game is reached only by playing: its address alone goes home', (tester) async {
    for (final game in ['/table', '/live']) {
      final router = await pumpAt(tester, game);
      expect(where(router), '/', reason: game);
      expect(find.text('home -'), findsOneWidget);
    }
  });

  testWidgets('the session\'s parameters stay in the address wherever it goes', (tester) async {
    final router = await pumpAt(tester, '/?lang=fr&e2e=1', boot: 'https://openhearts.game/play/?lang=fr&e2e=1');
    router.push(located('/about'));
    await tester.pumpAndSettle();
    final at = Uri.parse(where(router));
    expect(at.path, '/about');
    expect(at.queryParameters, {'lang': 'fr', 'e2e': '1'});
    router.go(located('/room/KP4T9MXR'));
    await tester.pumpAndSettle();
    expect(Uri.parse(where(router)).queryParameters, {'lang': 'fr', 'e2e': '1'});
  });

  testWidgets('a game opened with the session\'s parameters in the address is the game, not the front door', (tester) async {
    final router = await pumpAt(tester, '/?e2e=1', boot: 'https://openhearts.game/play/?e2e=1');
    router.push(located(tablePath), extra: const SoloGame(seed: 4, paced: false));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsOneWidget, reason: where(router));
    expect(Uri.parse(where(router)).path, tablePath);
    expect(Uri.parse(where(router)).queryParameters, {'e2e': '1'});
  });

  test('Stripe sends the browser back to the page that left for it', () {
    final at = Uri.parse('https://openhearts.game/play/subscription?lang=fr');
    final back = Uri.parse(returnAddress(at, bought: false));
    expect(back.path, '/play/subscription');
    expect(back.queryParameters, {'lang': 'fr'});
    expect(Uri.parse(returnAddress(at, bought: true)).queryParameters, {'lang': 'fr', 'bought': '1'});
  });
}
