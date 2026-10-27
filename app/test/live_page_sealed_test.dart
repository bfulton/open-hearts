/// The live page at sealed tables, and tables the house holds bot seats
/// at: the deal on the screen, the hands that are not this device's to
/// see, a deal worker that fails, the house gone, a hand given up. The
/// rest of the live page, and the harness both use, are
/// live_page_test.dart's.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/report_error.dart' show noticed;
import 'package:open_hearts/pacing.dart' show Pacing;
import 'package:open_hearts/table_model.dart';
import 'package:open_hearts/ui/table_view.dart' show TableView;
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

import 'live_page_test.dart' show act, harnessSeat, pumpLive;

const _me = harnessSeat;

void main() {
  testWidgets('a bot seat the house holds plays from the log, and its hand is no more open than a person\'s', (tester) async {
    // A seat the house holds has no hand to show this screen
    // (docs/explanation/live-play.md): its moves come off the log like a
    // person's, and a screen that waited for its hand would stop at the
    // pass and never play.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3});
    for (var guard = 0; guard < 200 && live.controller.game.phase == engine.Phase.dealing; guard++) {
      await live.advance(tester, 500);
    }
    expect(live.controller.game.phase, engine.Phase.passing, reason: 'the deal completed with two seats the house holds');
    final rules = live.controller.client.rules;
    expect([rules.actorOf(1), rules.actorOf(3)], everyElement(live.houseSigner.publicKey), reason: 'the house to each bot seat');
    for (var s = 0; s < engine.seatCount; s++) {
      expect(live.controller.game.knowsHand(s), s == _me, reason: 'seat $s\'s cards, as this screen has them');
    }

    // Past the pass and into the play: the bots' passes and plays are
    // the house's to say, and the screen takes them as they land.
    await act(tester, live);
    for (var guard = 0; guard < 200 && live.controller.game.phase != engine.Phase.playing; guard++) {
      await live.advance(tester, 500);
    }
    expect(live.controller.game.phase, engine.Phase.playing, reason: 'the screen moved past the pass');
    for (var guard = 0; guard < 200 && live.controller.game.tricksPlayed < 2; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(live.controller.game.tricksPlayed, greaterThanOrEqualTo(2), reason: 'tricks are played on the screen');
    expect(live.controller.game.knowsHand(1), isFalse, reason: 'and the bot\'s hand was never opened to do it');
    expect(tester.takeException(), isNull);
  });

  testWidgets('with the deal\'s work at a worker, the screen deals and plays and makes none of it itself', (tester) async {
    // The app's own arrangement: every device's shuffles and checks
    // made in a worker, here one taking a browser's time over each on
    // the virtual clock. The screen's table waits for them, and the
    // deal it shows is the one it would have shown making them itself.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, workers: true);
    var sawShuffling = false;
    for (var guard = 0; guard < 200 && live.controller.game.phase == engine.Phase.dealing; guard++) {
      await live.advance(tester, 500);
      if (find.textContaining('Shuffling').evaluate().isNotEmpty) sawShuffling = true;
    }
    expect(sawShuffling, isTrue, reason: 'the rail showed the shuffles while the worker made them');
    expect(live.controller.game.phase, engine.Phase.passing, reason: 'the deal completed');
    expect(live.controller.game.knowsHand(_me), isTrue);
    for (var guard = 0; guard < 200 && live.controller.game.tricksPlayed < 2; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(live.controller.game.tricksPlayed, greaterThanOrEqualTo(2), reason: 'and the hand plays');
    expect(live.myWorker!.made, greaterThanOrEqualTo(10), reason: 'a shuffle, two batches of tokens and seven checks, at the worker');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a device whose deal worker fails for good says so, leaves the table, tells the operator, and the others play on', (tester) async {
    final crypto = await rememberedCrypto();
    final lines = <(String, Map<String, String>)>[];
    noticed = (message, attributes) => lines.add((message, attributes));
    addTearDown(() => noticed = null);
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, workers: true);
    live.myWorker!.dead = true;
    for (var guard = 0; guard < 200 && live.controller.client.cannotDeal == null; guard++) {
      await live.advance(tester, 500);
    }
    expect(live.controller.client.cannotDeal, isNotNull, reason: 'the device learned it cannot deal');
    await live.advance(tester, 500);
    expect(find.text('This device can\'t deal'), findsOneWidget);
    expect(find.text('A bot took your seat'), findsNothing, reason: 'the table heard it; its deal is what broke');
    expect(find.widgetWithText(FilledButton, 'Home'), findsOneWidget);
    expect(find.byType(TableView), findsNothing, reason: 'nothing at the table left for this device to do');
    final other = live.people.values.first.client;
    for (var guard = 0; guard < 200 && other.rules.removals[_me] == null; guard++) {
      await live.advance(tester, 500);
    }
    expect(other.rules.removals[_me]?.exit, Exit.left, reason: 'it left, and the table took the leave: ${other.rules.describe()}');
    expect(lines.map((l) => l.$1), [startsWith('live: cannot deal: ')], reason: 'told of once');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the house gone mid-hand ends the game: a connection failure, the server stopped answering, told of once', (tester) async {
    // The house plays the bot seats, and nobody else can: gone, its
    // turn runs out, the table waits on it a while past that for a
    // restart, and then the game ends — unscored, and said so plainly.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3});
    final lines = <(String, Map<String, String>)>[];
    noticed = (message, attributes) => lines.add((message, attributes));
    addTearDown(() => noticed = null);
    for (var guard = 0; guard < 200 && live.controller.game.phase != engine.Phase.playing; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(live.controller.game.phase, engine.Phase.playing, reason: 'the hand was dealt and passed');
    live.house.close();
    for (var guard = 0; guard < 400 && !live.controller.failed; guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.tableState, TableState.failed, reason: live.controller.client.rules.describe());
    await live.advance(tester, 1000);
    expect(find.text('Connection failure'), findsOneWidget);
    expect(find.text("The game's server stopped answering"), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Home'), findsOneWidget);
    expect(find.byType(TableView), findsNothing, reason: 'nothing left at the table to do');
    expect(live.controller.done, isFalse, reason: 'unscored');
    expect(lines, hasLength(1));
    final (message, attributes) = lines.single;
    expect(message, 'live: game lost: the house let a turn run out');
    expect(attributes['seen'], allOf(startsWith('failed at #'), endsWith('line up')), reason: 'lost with this device\'s line up');
    for (var s = 0; s < 10; s++) {
      await live.advance(tester, 1000);
    }
    // And not again for the line going and coming back after.
    live.myLine.hold();
    await live.advance(tester, 5000);
    live.myLine.release();
    for (var s = 0; s < 5; s++) {
      await live.advance(tester, 1000);
    }
    expect(lines, hasLength(1), reason: 'once');
    expect(tester.takeException(), isNull);
  });

  testWidgets('at a sealed table the deal shows, the others\' cards are backs, and the hand plays out', (tester) async {
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto);
    var sawDealing = false;
    for (var guard = 0; guard < 60 && live.controller.game.phase == engine.Phase.dealing; guard++) {
      if (find.textContaining('Shuffling').evaluate().isNotEmpty || find.textContaining('Dealing').evaluate().isNotEmpty) sawDealing = true;
      await live.advance(tester, 100);
    }
    expect(sawDealing, isTrue, reason: 'the rail showed the deal');
    expect(live.controller.game.phase, engine.Phase.passing);
    expect(live.controller.game.knowsHand(_me), isTrue);
    for (var s = 0; s < engine.seatCount; s++) {
      if (s == _me) continue;
      expect(live.controller.game.knowsHand(s), isFalse, reason: 'seat $s\'s cards are not mine to see');
      expect(live.controller.game.handSizeOf(s), 13);
    }
    expect(find.text('Pass'), findsOneWidget);
    await act(tester, live);
    await live.advance(tester, 2000);
    expect(live.controller.game.phase, engine.Phase.playing);
    // Ada leaves after a few tricks: her hand is opened from the pieces
    // the others and the house hold, every side plays it at once, and
    // the shown game — behind, at its own pace — shows it right.
    var left = false;
    for (var guard = 0; guard < 400 && live.controller.game.handNumber == 0; guard++) {
      if (!left && live.controller.client.game.tricksPlayed >= 3) {
        live.people[0]!.depart(Going.leave);
        left = true;
      }
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(left, isTrue);
    expect(live.controller.personaAt(0), isNotNull, reason: 'a bot holds seat 0');
    expect(live.controller.game.handNumber, 1, reason: 'the first hand finished');
    final c = live.controller.client;
    final v = verifyRecord(GameRecord.of(c), crypto: crypto, house: live.houseSigner.publicKey, allowUnfinished: !c.done);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.removals, {0: Exit.left});
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('a hand given up gives way on the screen to the next, with no sheet', (tester) async {
    // Whoever holds the two of clubs says it is nowhere: nobody can lead,
    // the hand is opened by its audits and given up, and the next one is
    // dealt (packages/table, rules.dart). Every other seat here says so;
    // the deal is this test's, and puts the card in one of theirs. A
    // screen that stayed in the old hand would wait for a lead that
    // never comes, and never offer the pass the table then waits on.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, conducts: {0: Lie.declare, 1: Lie.declare, 3: Lie.declare});
    final c = live.controller;
    // The table and the screen on one clock, the screen's own beat
    // between the table giving the hand up and the screen going with
    // it: the felt as it was, a moment, then the next hand.
    var at = 0;
    int? gaveUp;
    for (var guard = 0; guard < 4000 && c.game.handNumber == 0; guard++) {
      if (gaveUp == null) await act(tester, live);
      await live.tick(tester, 100);
      at += 100;
      if (gaveUp == null && c.client.game.handNumber > 0) gaveUp = at;
    }
    expect(c.client.rules.removals.values.map((r) => (r.exit, r.hand)), contains((Exit.lied, 0)), reason: c.client.rules.describe());
    expect(gaveUp, isNotNull, reason: 'the table gave the hand up');
    expect(at - gaveUp!, greaterThanOrEqualTo(Pacing.sweepBeat.inMilliseconds - 100), reason: 'the screen held the felt a beat');

    // And the screen goes with it, to the pass of the hand the table
    // deals in its place — given up again, if the next liar is dealt
    // the card — with no sheet on the way: nothing was scored.
    for (var guard = 0; guard < 400 && !(c.awaitingPass && c.game.handNumber == c.client.game.handNumber); guard++) {
      await live.advance(tester, 500);
    }
    expect(c.awaitingPass, isTrue, reason: c.behind);
    expect(c.game.handNumber, greaterThan(0), reason: 'the screen shows a hand after the one given up: ${c.behind}');
    expect(find.text('Pass'), findsOneWidget);
    expect(c.handJustEnded, isNull);
    expect(c.game.totals, everyElement(0));
    for (final MapEntry(key: seat, value: r) in c.client.rules.removals.entries) {
      expect(r.exit, Exit.lied);
      expect(c.personaAt(seat), isNotNull, reason: 'a bot in seat $seat, which lied');
    }
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('a hand that ends while the others play on gives way to the next', (tester) async {
    final live = await pumpLive(tester);
    final c = live.controller;
    // The last trick of a hand is swept and the screen holds a beat of
    // bare felt before the sheet. The table does not hold with it: the
    // next hand is dealt and passed while the beat runs, so for as long
    // as the beat lasts the record is ahead of what is shown.
    for (var guard = 0; guard < 900 && c.client.game.handNumber < 1; guard++) {
      await act(tester, live);
      await live.tick(tester, 200);
    }
    expect(c.client.game.handNumber, 1, reason: 'the table is into the second hand');

    // And the screen follows it there. A hand that has ended is a place
    // the shown game passes through, never one it can be left in.
    for (var guard = 0; guard < 300 && c.game.handNumber < 1; guard++) {
      await act(tester, live);
      await live.tick(tester, 200);
    }
    expect(c.game.handNumber, 1, reason: 'the screen shows the new hand: ${c.behind}');
    expect(c.handShown, isNotEmpty, reason: 'with cards to play: ${c.behind}');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
