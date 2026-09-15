/// The front door, driven the way a thumb drives it: your name and
/// your avatar are on it, the three ways in are on it, and the game
/// the live buttons are about to ask for is on it and kept.
///
/// Nothing here reaches a relay — `online: false` keeps the device off
/// them — so what is proved is the screen and what it remembers, not
/// the seating.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpHome(WidgetTester tester, {String? openRoom}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(still(HomePage(openRoom: openRoom, online: false)));
  await tester.pumpAndSettle();
}

/// The door with nothing moving on it: the heart at the top folds and
/// opens for as long as the app is open (ui/folding_heart.dart), so a
/// test that waits for the screen to come to rest has to ask for the
/// same stillness a reader can ask for.
Widget still(Widget home) => MaterialApp(
      theme: buildTheme(),
      home: MediaQuery(data: const MediaQueryData(disableAnimations: true), child: home),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('one screen: who you are, and the three ways in', (tester) async {
    await pumpHome(tester);
    expect(find.text('Open Hearts'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Your name'), findsOneWidget);
    expect(find.bySemanticsLabel('Your avatar'), findsOneWidget);
    const buttons = ['Play bots', 'Play live', 'Play friends'];
    for (final label in buttons) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is on the front door');
    }
    final tops = [for (final label in buttons) tester.getTopLeft(find.text(label)).dy];
    expect(tops, orderedEquals(<double>[...tops]..sort()), reason: 'bots, live, friends, in that order down the screen');
    // The name is yours from the moment it is typed, not something a
    // button collects on the way past.
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Ada');
    await tester.pumpAndSettle();
    expect(await Identity.name(), 'Ada');
  });

  testWidgets('the options line says what the next game is; the sheet changes it and the device keeps it', (tester) async {
    await pumpHome(tester);
    expect(find.text('50 points · rated'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Game options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('100 points'));
    await tester.tap(find.text('Unrated'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('100 points · unrated'), findsOneWidget);
    final kept = await GameOptions.load();
    expect(kept.target, 100);
    expect(kept.rated, isFalse);
  });

  testWidgets('Play bots plays the game the options ask for', (tester) async {
    SharedPreferences.setMockInitialValues({'game_target': 100});
    await pumpHome(tester);
    await tester.tap(find.text('Play bots'));
    await tester.pumpAndSettle();
    expect(tester.widget<TablePage>(find.byType(TablePage)).target, 100);
    expect(find.text('Hand 1  ·  Pass left  ·  to 100'), findsOneWidget);
  });

  testWidgets('with live play locked there is a padlock and no way in, not even a link', (tester) async {
    liveOpen = false;
    addTearDown(() => liveOpen = true);
    // A name on the device and a room link in the address: the way
    // into a room that asks for no button at all.
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpHome(tester, openRoom: 'ABCD');
    expect(find.text('Play bots'), findsOneWidget, reason: 'the bots are free, always');
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.text('Not open yet'), findsOneWidget);
    expect(find.text('Play live'), findsNothing);
    expect(find.text('Play friends'), findsNothing);
    expect(find.text('Share the link'), findsNothing, reason: 'the link did not open a room either');
  });
}
