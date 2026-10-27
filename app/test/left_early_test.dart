/// The wait after leaving a live game early (live/left_early.dart): how
/// much of it is left, what the device keeps of it, and the front door
/// counting it down — Play live shut and saying until when, the other
/// ways to play open, and Play live open again once it is over.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/live/left_early.dart';
import 'package:open_hearts/live/live_controller.dart';
import 'package:open_hearts/live/lobby.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_page_test.dart' show licenceThisDevice, still;

const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

const _minute = 60 * 1000;

void main() {
  final originalNow = LeftEarly.nowMs;
  var now = DateTime.utc(2026, 10, 26, 12).millisecondsSinceEpoch;

  setUp(() {
    now = DateTime.utc(2026, 10, 26, 12).millisecondsSinceEpoch;
    LeftEarly.nowMs = () => now;
    SharedPreferences.setMockInitialValues({});
    RemoteSettings.current = RemoteSettings();
    Entitlement.current = Entitlement(service: _service);
  });
  tearDown(() {
    LeftEarly.nowMs = originalNow;
    RemoteSettings.current = RemoteSettings();
    Entitlement.current = Entitlement();
  });

  group('what is left of the wait', () {
    const five = Duration(minutes: 5);

    test('the wait less the time since, and nothing once it is over', () {
      expect(LeftEarly.left(atMs: 0, nowMs: 0, wait: five), five);
      expect(LeftEarly.left(atMs: 0, nowMs: 2 * _minute, wait: five), const Duration(minutes: 3));
      expect(LeftEarly.left(atMs: 0, nowMs: 5 * _minute - 1, wait: five), const Duration(milliseconds: 1));
      expect(LeftEarly.left(atMs: 0, nowMs: 5 * _minute, wait: five), isNull);
      expect(LeftEarly.left(atMs: 0, nowMs: 60 * _minute, wait: five), isNull);
    });

    test('nothing left early, or no wait at all, is nothing to wait for', () {
      expect(LeftEarly.left(atMs: null, nowMs: 0, wait: five), isNull);
      expect(LeftEarly.left(atMs: 0, nowMs: 0, wait: Duration.zero), isNull);
    });

    test('never more than the wait, whatever the clock did', () {
      expect(LeftEarly.left(atMs: 10 * _minute, nowMs: 0, wait: five), five, reason: 'a clock set back');
    });

    test('the operator\'s wait is the one counted, from when the game was left', () {
      expect(LeftEarly.left(atMs: 0, nowMs: 2 * _minute, wait: const Duration(minutes: 30)), const Duration(minutes: 28));
      expect(LeftEarly.left(atMs: 0, nowMs: 2 * _minute, wait: const Duration(minutes: 1)), isNull);
    });
  });

  test('the device keeps the later of two times, and lets it go when told', () async {
    expect(await LeftEarly.load(), isNull);
    await LeftEarly.mark(1000);
    expect(await LeftEarly.load(), 1000);
    await LeftEarly.mark(500);
    expect(await LeftEarly.load(), 1000, reason: 'an earlier one is not a later wait');
    await LeftEarly.mark(2000);
    expect(await LeftEarly.load(), 2000);
    await LeftEarly.clear();
    expect(await LeftEarly.load(), isNull);
  });

  /// The front door, licensed, with nothing moving that a countdown does
  /// not move: not settled, since a countdown never settles.
  Future<void> door(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await Entitlement.current.load((await Identity.signer()).publicKey);
    await licenceThisDevice();
    await tester.pumpWidget(still(const HomePage(online: false)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  ButtonStyleButton button(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()).first);

  /// A second of the device's time, and of the screen's.
  Future<void> second(WidgetTester tester, {int seconds = 1}) async {
    for (var i = 0; i < seconds; i++) {
      now += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('after a game left early, Play live waits and says until when; the rest of the door is open', (tester) async {
    SharedPreferences.setMockInitialValues({'live.leftEarlyAt': now - _minute});
    await door(tester);
    expect(find.text("You didn't finish your last live game: Play live opens again in 4:00."), findsOneWidget);
    expect(button(tester, 'Play live').onPressed, isNull, reason: 'Play live is shut');
    expect(button(tester, 'Play friends').onPressed, isNotNull, reason: 'friends are not strangers');
    expect(button(tester, 'Play solo').onPressed, isNotNull);

    // Counted down a second at a time.
    await second(tester);
    expect(find.text("You didn't finish your last live game: Play live opens again in 3:59."), findsOneWidget);

    // And once it is over, Play live opens again, and the device lets
    // the time go.
    await second(tester, seconds: 239);
    expect(find.textContaining("You didn't finish your last live game"), findsNothing);
    expect(button(tester, 'Play live').onPressed, isNotNull);
    expect((await SharedPreferences.getInstance()).getInt('live.leftEarlyAt'), isNull);
  });

  testWidgets('the countdown counts a part of a second as a second: the door never says 0:00 while Play live is shut', (tester) async {
    SharedPreferences.setMockInitialValues({'live.leftEarlyAt': now - 5 * _minute + 1500});
    await door(tester);
    expect(find.text("You didn't finish your last live game: Play live opens again in 0:02."), findsOneWidget);
    await second(tester);
    expect(find.text("You didn't finish your last live game: Play live opens again in 0:01."), findsOneWidget,
        reason: 'half a second left is a second to wait, not none');
    expect(button(tester, 'Play live').onPressed, isNull);
    await second(tester);
    expect(find.textContaining("You didn't finish your last live game"), findsNothing);
    expect(button(tester, 'Play live').onPressed, isNotNull);
  });

  testWidgets('the wait is the operator\'s: none at all where it is set to none', (tester) async {
    SharedPreferences.setMockInitialValues({'live.leftEarlyAt': now - _minute});
    RemoteSettings.current.adopt(RemoteConfig.parse({'leftEarlyMin': 0}));
    await door(tester);
    expect(find.textContaining("You didn't finish your last live game"), findsNothing);
    expect(button(tester, 'Play live').onPressed, isNotNull);
  });

  testWidgets('and longer where it is set longer', (tester) async {
    SharedPreferences.setMockInitialValues({'live.leftEarlyAt': now - _minute});
    RemoteSettings.current.adopt(RemoteConfig.parse({'leftEarlyMin': 30}));
    await door(tester);
    expect(find.text("You didn't finish your last live game: Play live opens again in 29:00."), findsOneWidget);
  });

  testWidgets('a wait already over when the door opens is nothing, and is let go', (tester) async {
    SharedPreferences.setMockInitialValues({'live.leftEarlyAt': now - 6 * _minute});
    await door(tester);
    expect(find.textContaining("You didn't finish your last live game"), findsNothing);
    expect(button(tester, 'Play live').onPressed, isNotNull);
    expect((await SharedPreferences.getInstance()).getInt('live.leftEarlyAt'), isNull);
  });

  testWidgets('during the wait the pool is not asked for, even asked directly', (tester) async {
    SharedPreferences.setMockInitialValues({'live.leftEarlyAt': now - _minute});
    var asked = false;
    late final AppLocalizations words;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(builder: (context) {
        words = context.l10n;
        return const SizedBox();
      }),
    ));
    final lobby = Lobby(
      who: () => throw StateError('nobody asked who this is'),
      options: () => const GameOptions(),
      named: () async {
        asked = true;
        return true;
      },
      words: () => words,
      seat: (LiveController controller) async => null,
      addressChanged: () {},
      openRoom: () => null,
    );
    await tester.pump();
    expect(lobby.leftEarlyWait, const Duration(minutes: 4));
    await lobby.play();
    expect(asked, isFalse, reason: 'no name asked for, no relay connected');
    expect(lobby.opening, isNull);
    expect(lobby.queue, isNull);
    expect(lobby.error, isNull, reason: 'nothing tried, so nothing went wrong');
    // Once the wait is over the same press goes on to the pool: on a
    // test's device, as far as its want of a deal lets it.
    now += 4 * _minute;
    await lobby.play();
    expect(lobby.error, isNotNull, reason: 'tried, and stopped only by the deal');
    // Gone with the door, and its countdown with it.
    lobby.dispose();
  });
}
