/// The front door, driven the way a thumb drives it: the three ways in
/// are on it, the game the live buttons are about to ask for is on it
/// and kept, and who you are is the icon in the corner.
///
/// Nothing here reaches a relay — `online: false` keeps the device off
/// them — so what is proved is the screen and what it remembers, not
/// the seating.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/room.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/folding_heart.dart';
import 'package:open_hearts/ui/header.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'room_test.dart' show Bus;

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

  test('a relay that answers late still counts; it is only said to be slow first', () async {
    final relay = Completer<void>();
    var said = 0;
    final waiting = waitForRelay(relay.future,
        slow: () => said++,
        sayIt: const Duration(milliseconds: 60),
        stopAt: const Duration(milliseconds: 2000));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(said, 1, reason: 'past the first deadline the screen says so');

    relay.complete();
    await waiting;
    expect(said, 1, reason: 'and the late answer is an answer, not a failure');
  });

  test('a relay that never answers gives up at the far deadline', () async {
    var said = 0;
    await expectLater(
      waitForRelay(Completer<void>().future,
          slow: () => said++,
          sayIt: const Duration(milliseconds: 40),
          stopAt: const Duration(milliseconds: 160)),
      throwsA(isA<TimeoutException>()),
    );
    expect(said, 1);
  });

  testWidgets('gold is what you can do: the mark is not gold, and the buttons are', (tester) async {
    await pumpHome(tester);
    // The app's own name and the heart over it say what this is, not
    // what to press, so they are not dressed as something to press.
    final name = tester.widget<Text>(find.text('Open Hearts')).style!;
    expect(name.color, Palette.mark);
    expect(name.color, isNot(Palette.gold));
    expect(tester.widget<FoldingHeart>(find.byType(FoldingHeart)).color, Palette.mark);

    // And gold is still doing its job, on the thing you press.
    final play = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Play bots'));
    expect(play.style!.backgroundColor!.resolve({}), Palette.gold);
  });

  testWidgets('one screen: the three ways in, and who you are in the corner', (tester) async {
    await pumpHome(tester);
    expect(find.text('Open Hearts'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'nothing is typed on the door any more');
    const buttons = ['Play bots', 'Play live', 'Play friends'];
    for (final label in buttons) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is on the front door');
    }
    final tops = [for (final label in buttons) tester.getTopLeft(find.text(label)).dy];
    expect(tops, orderedEquals(<double>[...tops]..sort()), reason: 'bots, live, friends, in that order down the screen');

    // Who you are is an icon in the top right, and the menu is in the
    // top left.
    final profile = tester.getCenter(find.bySemanticsLabel('Your profile'));
    expect(profile.dx, greaterThan(195), reason: 'the right half of a 390-wide screen');
    expect(profile.dy, lessThan(60), reason: 'up in the chrome, not in the body');
    expect(tester.getCenter(find.bySemanticsLabel('Menu')).dx, lessThan(195));

    // And the name is given in there, with the avatar, and kept on the
    // device.
    await tester.tap(find.bySemanticsLabel('Your profile'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Ada');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await Identity.name(), 'Ada');
    expect(find.text('A'), findsOneWidget, reason: 'the icon in the corner wears her initial');
  });

  testWidgets('a link to a room, on a device with no name, asks for one in the profile', (tester) async {
    await pumpHome(tester, openRoom: 'KP4T9MXR');
    expect(find.text('My initials'), findsOneWidget, reason: 'the profile itself, not a field on the page');
    expect(find.widgetWithText(TextField, 'Your name'), findsOneWidget,
        reason: 'the room needs a name, and the profile is where a name is given');
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

  testWidgets('About is behind the menu, the same control the table carries', (tester) async {
    await pumpHome(tester);
    expect(find.text('About'), findsNothing, reason: 'no button of its own at the bottom of the door');
    expect(find.byType(MenuButton), findsOneWidget, reason: 'the table\'s menu, not a lookalike of it');
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('Build'), findsOneWidget, reason: 'the about page');
  });

  testWidgets('the room says who is here and how to bring the rest, and never says the code', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final room = Room(channel: Bus().attach(FakeSigner('a')), code: 'KP4T9MXR', myName: 'Ada');
    await tester.pumpWidget(still(Scaffold(
      body: RoomView(room: room, ledger: null, onLeave: () {}, onShare: () {}),
    )));
    await tester.pump();
    expect(find.text('Ada (you)'), findsOneWidget);
    expect(find.text('Share the link'), findsOneWidget);
    expect(find.textContaining('KP4T9MXR'), findsNothing, reason: 'the link is the way in; the code is not for reading off a screen');
    room.dispose();
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
    await pumpHome(tester, openRoom: 'KP4T9MXR');
    expect(find.text('Play bots'), findsOneWidget, reason: 'the bots are free, always');
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.text('Not open yet'), findsOneWidget);
    expect(find.text('Play live'), findsNothing);
    expect(find.text('Play friends'), findsNothing);
    expect(find.text('Share the link'), findsNothing, reason: 'the link did not open a room either');
  });
}
