/// The live page at sealed tables and tables a jury holds seats at: the
/// deal on the screen, the hands that are not this device's to see, a
/// deal worker that fails, a hand given up. The rest of the live page,
/// and the harness both use, are live_page_test.dart's.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/table_model.dart';
import 'package:open_hearts/ui/table_view.dart' show TableView;
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

import 'live_page_test.dart' show act, harnessSeat, pumpLive;

const _me = harnessSeat;

void main() {
  testWidgets('a bot seat a juror holds plays from the record, and its hand is no more open than a person\'s', (tester) async {
    // The screen works a bot's moves out for itself, which it can only
    // do with the bot's hand in front of it. A seat a juror holds has
    // no hand to show it (docs/explanation/live-play.md), so its moves have to
    // come off the record like a person's — and a screen that waited
    // for the hand instead would stop at the pass and never play.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, jurors: 4);
    for (var guard = 0; guard < 200 && live.controller.game.phase == engine.Phase.dealing; guard++) {
      await live.advance(tester, 500);
    }
    expect(live.controller.game.phase, engine.Phase.passing, reason: 'the deal completed with two seats held by jurors');
    final held = live.controller.client.botHolders(0);
    expect(held.keys.toSet(), {1, 3}, reason: 'a juror to each bot seat');
    for (var s = 0; s < engine.seatCount; s++) {
      expect(live.controller.game.knowsHand(s), s == _me, reason: 'seat $s\'s cards, as this screen has them');
    }

    // Past the pass and into the play: the bots' passes and plays are
    // the jurors' to say, and the screen takes them as they land.
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
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, jurors: 4, workers: true);
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
    expect(live.controller.client.dealCallsRefused, 0, reason: 'none of the deal\'s slow calls asked for where the screen is drawn');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a device whose deal worker fails for good says so, leaves the table, and the others play on', (tester) async {
    final crypto = await rememberedCrypto();
    // What is raised where nothing catches it — the worker's failure —
    // is kept here. The body's own failures come back out as a value:
    // an error does not cross from a zone with a handler of its own
    // into the test's, and an expectation that failed in there would
    // leave the test waiting for ever rather than failing it.
    final raised = <Object>[];
    final zone = Zone.current.fork(specification: ZoneSpecification(handleUncaughtError: (self, parent, z, e, st) => raised.add(e)));
    final failed = await zone.run(() async {
      try {
        final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, jurors: 4, workers: true);
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
        for (var guard = 0; guard < 200 && !other.record.any((d) => d.removal && d.event.seat == _me); guard++) {
          await live.advance(tester, 500);
        }
        expect(other.record.any((d) => d.removal && d.event.seat == _me && d.event.kind == EventKind.leave), isTrue,
            reason: 'it left, and the table carried the leave: ${other.describe()}');
        return null;
      } catch (e, st) {
        return (e, st);
      }
    });
    if (failed != null) Error.throwWithStackTrace(failed.$1, failed.$2);
    expect(raised, [isA<DealWorkFailed>()], reason: 'the failure raised, once, and nothing else');
  });

  testWidgets('a hand nobody left can open ends the game: a connection failure, juror quorum lost', (tester) async {
    // The jury holding the bot seats gone mid-hand, all of it: the
    // table stops at a held seat's turn and says it waits for the
    // jury, and when none has come back in the time a silent person
    // is given, the game ends — unscored, and said so plainly.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, jurors: 4);
    for (var guard = 0; guard < 200 && live.controller.game.phase != engine.Phase.playing; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(live.controller.game.phase, engine.Phase.playing, reason: 'the hand was dealt and passed');
    for (final j in live.jurors) {
      live.net.goOffline(j.signer.publicKey);
    }
    for (var guard = 0; guard < 400 && live.controller.client.failure == null; guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.client.failure, Failure.jurorQuorumLost, reason: live.controller.client.describe());
    expect(find.text('Connection failure'), findsOneWidget);
    expect(find.text('Juror quorum lost'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Home'), findsOneWidget);
    expect(find.byType(TableView), findsNothing, reason: 'nothing left at the table to do');
    expect(live.controller.done, isFalse, reason: 'unscored');
    expect(tester.takeException(), isNull);
  });

  testWidgets('at a sealed table the deal shows, the others\' cards are backs, and the hand plays out', (tester) async {
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto);
    // The deal runs on the virtual clock: keys wait up to ten seconds
    // for a jury there is none of here, then the shuffles and the
    // rest. Somewhere along it the rail says so.
    var sawDealing = false;
    for (var guard = 0; guard < 60 && live.controller.game.phase == engine.Phase.dealing; guard++) {
      await live.advance(tester, 500);
      if (find.textContaining('Shuffling').evaluate().isNotEmpty || find.textContaining('Dealing').evaluate().isNotEmpty) sawDealing = true;
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
    // Ada leaves after a few tricks: her hand is opened from the
    // pieces the others hold, her bot plays it at the table at once,
    // and the shown game — behind, at its own pace — shows it right.
    var left = false;
    for (var guard = 0; guard < 400 && live.controller.game.handNumber == 0; guard++) {
      if (!left && live.controller.client.game.tricksPlayed >= 3) {
        live.people[0]!.depart(Exit.leave);
        left = true;
      }
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(left, isTrue);
    expect(live.controller.personaAt(0), isNotNull, reason: 'a bot holds seat 0');
    expect(live.controller.game.handNumber, 1, reason: 'the first hand finished');
    final c = live.controller.client;
    final v = verifyRecord(c.spec, c.record, allowPartial: !c.done, juries: c.juries, crypto: crypto, releases: c.releases);
    expect(v.ok, isTrue, reason: v.reason);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('a hand given up in its deal gives way on the screen to the next', (tester) async {
    // A bot seat's juror goes while the seat still owes a step of the
    // deal. Nobody else holds the key it deals with, so the table gives
    // the hand up undealt and deals the next (packages/table,
    // undealt_hand_test.dart). A screen that stayed in the old hand's
    // deal would wait for a lead that deal never names, and never offer
    // the pass the table then waits on.
    final crypto = await rememberedCrypto();
    final live = await pumpLive(tester, crypto: crypto, botSeats: const {1, 3}, jurors: jurySize + 4);
    final c = live.controller;
    for (var guard = 0; guard < 200 && c.client.botHolders(0).isEmpty; guard++) {
      await live.advance(tester, 500);
    }
    final held = c.client.botHolders(0);
    expect(held, isNotEmpty, reason: 'a jury holds the bot seats');
    expect(c.client.game.phase, engine.Phase.dealing, reason: 'still in the deal when the holder goes');
    live.net.goOffline(held.values.first);
    for (var guard = 0; guard < 400 && c.client.game.handNumber == 0; guard++) {
      await live.advance(tester, 500);
    }
    expect(c.client.handOutcome(0), HandState.abandoned, reason: c.client.describe());

    // And the screen goes with it, to the pass of the hand dealt in its
    // place, with no sheet on the way: nothing was scored.
    for (var guard = 0; guard < 200 && !c.awaitingPass; guard++) {
      await live.advance(tester, 500);
    }
    expect(c.game.handNumber, 1, reason: 'the screen shows the next hand: ${c.behind}');
    expect(c.awaitingPass, isTrue, reason: c.behind);
    expect(find.text('Pass'), findsOneWidget);
    expect(c.handJustEnded, isNull);
    expect(c.game.totals, everyElement(0));
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
