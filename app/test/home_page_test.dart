/// The front door, driven the way a thumb drives it: the three ways in
/// are on it, the game the live buttons are about to ask for is on it
/// and kept, and who you are is the icon in the corner.
///
/// Nothing here reaches a relay — `online: false` keeps the device off
/// them — so what is proved is the screen and what it remembers, not
/// the seating.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/crypto/deal.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/room.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/folding_heart.dart';
import 'package:open_hearts/ui/header.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'household_test.dart' show signedFor, standUp;
import 'room_test.dart' show Bus;

/// A service of this test's own: BIP-340's published pair, so the
/// licences here are signed the way the real one signs them and checked
/// the way the app checks that one.
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// Live play open on this device, the only way it is ever open: a
/// licence with a date on it, signed by the service this build names.
Future<void> licenceThisDevice({int days = 30}) async {
  final device = (await Identity.signer()).publicKey;
  final day = DateTime.now().toUtc().add(Duration(days: days));
  final until = DateTime.utc(day.year, day.month, day.day);
  final unsigned = Licence(key: device, until: until, plan: 'year', signature: '');
  await Entitlement.current.load(device);
  await Entitlement.current.adopt(Licence(
    key: device,
    until: until,
    plan: 'year',
    signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest),
  ));
}

Future<void> pumpHome(WidgetTester tester, {String? openRoom, String? openClaim, bool live = true, bool online = false}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // What main() does before the first frame: the device's standing is
  // read off the device, licensed or not (entitlement.dart).
  await Entitlement.current.load((await Identity.signer()).publicKey);
  if (live) await licenceThisDevice();
  await tester.pumpWidget(still(HomePage(openRoom: openRoom, openClaim: openClaim, online: online)));
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
  // A device that can run the deal, as every device that plays live
  // is — the primitives and the worker that makes the slow ones: the
  // one that cannot is a test of its own (below).
  setUpAll(() async {
    dealCrypto = await DealCrypto.load();
    dealWorker = await DealWorker.start();
  });
  tearDownAll(() => dealWorker?.close());

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Every test stands up a service of its own, and takes it down
    // again: the standing of this device is a global, like its
    // identity (entitlement.dart).
    Entitlement.current = Entitlement(service: _service);
  });
  tearDown(() => Entitlement.current = Entitlement());

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
    final play = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Play solo'));
    expect(play.style!.backgroundColor!.resolve({}), Palette.gold);
  });

  testWidgets('the spinner belongs to the button that was pressed', (tester) async {
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    await pumpHome(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Play friends'));
    await tester.pump();
    await tester.pump();
    final spinners = find.byType(CircularProgressIndicator);
    expect(spinners, findsOneWidget, reason: 'one way in is being opened, so one spinner');
    expect(
      find.descendant(of: find.widgetWithText(FilledButton, 'Play friends'), matching: spinners),
      findsOneWidget,
      reason: 'and it is on the button that was pressed',
    );
    expect(
      find.descendant(of: find.widgetWithText(FilledButton, 'Play live'), matching: spinners),
      findsNothing,
      reason: 'not on the one that was not',
    );

    // Let the wait run out, so the relay it opened is closed behind it.
    await tester.pump(stopWaiting + const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('one screen: the three ways in, and who you are in the corner', (tester) async {
    await pumpHome(tester);
    expect(find.text('Open Hearts'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'nothing is typed on the door any more');
    const buttons = ['Play solo', 'Play live', 'Play friends'];
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

  testWidgets('Play solo plays the game the options ask for', (tester) async {
    SharedPreferences.setMockInitialValues({'game_target': 100});
    await pumpHome(tester);
    await tester.tap(find.text('Play solo'));
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

  testWidgets('unlicensed there is no way into a live game, not even a link — and a price instead', (tester) async {
    // A name on the device and a room link in the address: the way
    // into a room that asks for no button at all.
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    await pumpHome(tester, openRoom: 'KP4T9MXR', live: false);
    expect(find.text('Play solo'), findsOneWidget, reason: 'playing alone is free, always');
    expect(find.text('Play live'), findsNothing);
    expect(find.text('Play friends'), findsNothing);
    expect(find.text('Share the link'), findsNothing, reason: 'the link did not open a room either');
    expect(find.text(r'$2.99 a year'), findsOneWidget, reason: 'what it costs, said on the door');
    expect(find.text('Subscribe'), findsOneWidget);
  });

  testWidgets('a device that cannot run the deal is told so at the door, and opens no table', (tester) async {
    final kept = dealCrypto;
    dealCrypto = null;
    addTearDown(() => dealCrypto = kept);
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    await pumpHome(tester);
    for (final way in ['Play friends', 'Play live']) {
      await tester.tap(find.text(way));
      await tester.pump();
      await tester.pump();
      expect(find.text(Room.noDeal()), findsOneWidget, reason: '$way: every live table is sealed');
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '$way: and nothing is being opened');
      expect(find.text('Share the link'), findsNothing, reason: '$way: no room either');
    }
  });

  testWidgets('a device whose deal worker failed for good is told to start afresh, and opens no table', (tester) async {
    final kept = dealWorker;
    dealWorker = _DeadWorker();
    addTearDown(() => dealWorker = kept);
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    await pumpHome(tester);
    for (final way in ['Play friends', 'Play live']) {
      await tester.tap(find.text(way));
      await tester.pump();
      await tester.pump();
      expect(find.text('The deal that keeps the cards honest stopped working. Restart the app to start afresh.'), findsOneWidget,
          reason: '$way: not that the build cannot run it — it did, and will again');
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '$way: and nothing is being opened');
    }
  });

  testWidgets('a licence run out is no licence, and one for another device is none either', (tester) async {
    await licenceThisDevice(days: -1);
    expect(Entitlement.current.live, isFalse, reason: 'yesterday is not a date you can play on');

    // Signed for somebody else's device, by the right service.
    final other = SchnorrSigner.generate().publicKey;
    final until = DateTime.now().toUtc().add(const Duration(days: 30));
    final day = DateTime.utc(until.year, until.month, until.day);
    final unsigned = Licence(key: other, until: day, plan: 'year', signature: '');
    final signed = Licence(
        key: other, until: day, plan: 'year', signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest));
    expect(await Entitlement.current.adopt(signed), isFalse);
    expect(Entitlement.current.live, isFalse);

    await pumpHome(tester, live: false);
    expect(find.text('Subscribe'), findsOneWidget);
  });

  testWidgets('a licence that arrives under the screen opens the door', (tester) async {
    await pumpHome(tester, live: false);
    expect(find.text('Play live'), findsNothing);
    await licenceThisDevice();
    await tester.pumpAndSettle();
    expect(find.text('Play live'), findsOneWidget, reason: 'the door opens when the licence lands');
    expect(find.text('Subscribe'), findsNothing);
  });

  testWidgets('a device arriving with a code is licensed by it', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('claim', {'licence': signedFor(me.publicKey)});
    await pumpHome(tester, openClaim: 'ab12cd34', live: false);
    await tester.pumpAndSettle();
    expect(stand.seen.single, contains('"ticket":"ab12cd34"'));
    expect(Entitlement.current.licence?.key, (await Identity.signer()).publicKey, reason: 'what came back');
    expect(Entitlement.current.live, isTrue);
    expect(find.text('Play live'), findsOneWidget, reason: 'the door is open on the device that scanned it');
  });

  testWidgets('a code already spent says so, and leaves the door where it was', (tester) async {
    // The same link opened twice — a refresh, or a second phone shown
    // the same photograph.
    final stand = standUp();
    stand.says('claim', {'error': 'that code has been used'}, status: 409);
    await pumpHome(tester, openClaim: 'ab12cd34', live: false);
    await tester.pumpAndSettle();
    expect(Entitlement.current.live, isFalse);
    expect(find.text('That code has been used.'), findsOneWidget);
    expect(find.text('Subscribe'), findsOneWidget);
  });

  testWidgets('shut, the door has the one way to live play, and the menu does not say it again', (tester) async {
    await pumpHome(tester, live: false);
    expect(find.widgetWithText(OutlinedButton, 'Subscribe'), findsOneWidget, reason: 'drawn, not filled: Play solo is the door\'s');
    expect(find.widgetWithText(FilledButton, 'Play solo'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Live play'), findsOneWidget, reason: 'the card on the door, and not a second one in the menu');
  });

  testWidgets('with live play open the menu is where the date on the licence is', (tester) async {
    await pumpHome(tester);
    expect(find.text('Play live'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live play'));
    await tester.pumpAndSettle();
    final until = Licence.dayOf(Entitlement.current.until!);
    expect(find.text('Open on this device, to $until'), findsOneWidget);
    expect(find.text('Subscribe'), findsNothing, reason: 'nothing to buy twice');
  });

  testWidgets('the page behind the price says what the money is for, and it is not the game', (tester) async {
    await pumpHome(tester, live: false);
    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Playing alone is free'), findsOneWidget);
    expect(find.textContaining('No server sees a hand'), findsOneWidget);
    expect(find.text(r'$2.99 a year'), findsOneWidget);
  });
}

/// A worker failed for good (packages/deal, ResilientDealWorker).
class _DeadWorker implements DealWorker {
  @override
  bool get dead => true;
  @override
  void run(DealJob job, {required void Function(Object answer) done, required void Function(Object error) failed}) => failed('dead');
  @override
  void close() {}
}
