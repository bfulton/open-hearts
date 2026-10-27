/// Whole games at a refereed table, on the simulator: the referee's log,
/// the rules every side applies to it, and the house holding the bot
/// seats of a sealed table (docs/explanation/live-play.md).
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// Every client came to the same table: the same log, the same totals,
/// the same state, and the house's word on it in the log.
void agree(SimTable t, {TableState state = TableState.finished, Set<String> except = const {}}) {
  expect(t.lockstepProblems(except: except), isEmpty, reason: 'every side saw the same table after every entry');
  final log = t.referee.log;
  for (final c in t.following) {
    expect(c.done, isTrue, reason: 'seat ${c.mySeat} has the game over');
    expect(c.state, state, reason: 'seat ${c.mySeat}');
    expect(c.game.totals, t.following.first.game.totals, reason: 'seat ${c.mySeat} has the same totals');
    expect(c.rules.endN, t.following.first.rules.endN);
    expect(c.rules.endHash, t.following.first.rules.endHash);
  }
  final first = t.following.first.rules;
  expect(first.log.length, lessThanOrEqualTo(log.length));
  if (t.spec.sealed && state != TableState.failed) {
    expect(first.result, isNotNull, reason: 'the house said how the game came out');
    expect(first.result!.author, t.houseSigner.publicKey);
  }
}

void main() {
  test('four people play a whole unsealed game', () {
    final t = SimTable(humans: 4, seed: 3);
    t.start();
    expect(t.run(), isTrue, reason: 'every client reaches the end');
    agree(t);
    expect(t.clients.first.game.phase, Phase.gameOver);
    expect(t.clients.first.rules.removals, isEmpty);
    t.close();
  });

  group('sealed', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    test('one person and three bots the house holds play a whole game', () {
      final t = SimTable(humans: 1, seed: 5, crypto: crypto);
      t.start();
      expect(t.clock.runUntil(() => t.clients.first.started && t.clients.first.game.phase == Phase.passing, limitMs: 120000), isTrue,
          reason: 'the first deal completes');
      final c = t.clients.first;
      for (var s = 0; s < seatCount; s++) {
        expect(c.game.knowsHand(s), s == c.mySeat, reason: 'seat $s as the person sees it');
      }
      expect(t.run(), isTrue, reason: 'the game plays out');
      agree(t);
      t.close();
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('four people play a whole sealed game', () {
      final t = SimTable(humans: 4, seed: 7, crypto: crypto);
      t.start();
      expect(t.run(), isTrue, reason: 'the game plays out');
      agree(t);
      expect(t.clients.first.rules.removals, isEmpty);
      t.close();
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('with the deal\'s slow calls made on a worker', () {
      final t = SimTable(humans: 2, seed: 44, crypto: crypto, workers: true);
      t.start();
      expect(t.run(), isTrue);
      agree(t);
      expect(t.clients.first.rules.removals, isEmpty);
    });

    test('three people, one going: the other two and the house play it out', () {
      final t = SimTable(humans: 3, seed: 45, crypto: crypto);
      t.people[1]
        ..going = Going.crash
        ..goAt = Moment.midTrick;
      t.start();
      expect(t.run(), isTrue);
      agree(t);
      expect(t.following.first.rules.removals.keys, [1]);
    });

    test('four people, two going in one hand', () {
      final t = SimTable(humans: 4, seed: 46, crypto: crypto);
      t.people[0]
        ..going = Going.leave
        ..goAt = Moment.offTurn;
      t.people[3]
        ..going = Going.offline
        ..goAt = Moment.offTurn;
      t.start();
      expect(t.run(), isTrue, reason: t.following.map((c) => c.rules.describe()).join('\n'));
      agree(t);
      final r = t.following.first.rules;
      expect(r.removals.keys, unorderedEquals([0, 3]));
    });

    test('both people gone at once ends the game, and does not fail it', () {
      final t = SimTable(humans: 2, seed: 47, crypto: crypto);
      for (final p in t.people) {
        p
          ..going = Going.crash
          ..goAt = Moment.handBoundary;
      }
      t.start();
      expect(t.run(), isTrue);
      final said = [for (final e in t.referee.log) if (e.event?.kind == EventKind.result) e.event!];
      expect(said, hasLength(1));
      expect(said.single.body['state'], TableState.ended.name);
    });

    group('the house', () {
      test('gone for good fails the game at its next turn, and nobody is rated', () {
        final t = SimTable(humans: 2, seed: 41, crypto: crypto);
        t.start();
        expect(t.clock.runUntil(() => t.clients.first.started && t.clients.first.game.handNumber == 1, limitMs: 30 * 60000), isTrue);
        final killedAt = t.clock.nowMs;
        t.killHouse();
        expect(t.run(), isTrue);
        agree(t, state: TableState.failed);
        final timing = t.spec.timing;
        expect(t.clock.nowMs - killedAt, lessThanOrEqualTo(timing.botDealsMs + timing.houseGraceMs + 2 * 60000),
            reason: 'the house\'s turn ran out within its grace, past whatever the people had open');
        expect(t.clients.first.rules.result, isNull, reason: 'nobody said how a failed game came out');
        expect(t.clients.first.rules.removals, isEmpty, reason: 'nobody lost their seat to the house going');
      });

      test('back within its grace carries the table on from the log', () {
        final t = SimTable(humans: 2, seed: 42, crypto: crypto);
        t.start();
        expect(t.clock.runUntil(() => t.clients.first.started && t.clients.first.game.handNumber == 1, limitMs: 30 * 60000), isTrue);
        t.restartHouse(afterMs: t.spec.timing.houseGraceMs ~/ 2);
        expect(t.run(), isTrue);
        agree(t);
        expect(t.clients.first.rules.removals, isEmpty);
        expect(t.referee.log.where((e) => e.down == t.houseSigner.publicKey), isNotEmpty, reason: 'the referee saw the house go');
      });
    });

    group('a reload', () {
      for (final at in Moment.all) {
        test('${at.name} comes back to the seat from the journal', () {
          final t = SimTable(humans: 2, seed: 51 + Moment.all.indexOf(at), crypto: crypto);
          var reloaded = false;
          t.start();
          expect(
              t.clock.runUntil(() {
                final c = t.clients.first;
                return c.started && c.game.handNumber >= at.fromHand && at.holds(c);
              }, limitMs: 30 * 60000),
              isTrue);
          t.reload(0, awayMs: t.spec.timing.silenceMs ~/ 3);
          reloaded = true;
          expect(t.run(), isTrue, reason: t.following.map((c) => c.rules.describe()).join('\n'));
          expect(reloaded, isTrue);
          agree(t);
          expect(t.clients.first.rules.removals, isEmpty, reason: 'nobody lost their seat');
          // Nothing said twice: the device back at the table said nothing
          // for a turn until it had read the log as far as it went.
          final said = <String, int>{};
          for (final e in t.referee.log) {
            final ev = e.event;
            if (ev == null || ev.author != t.signers[0].publicKey || !ev.body.containsKey('turn')) continue;
            said['${ev.turn}'] = (said['${ev.turn}'] ?? 0) + 1;
          }
          expect({for (final e in said.entries) if (e.value > 1) e.key: e.value}, isEmpty);
          expect(t.journals[0].secretFor(t.clients.first.game.handNumber), isNotNull, reason: 'the journal kept the last hand\'s secret');
        });
      }
    });

    test('a reload whose last step reaches the log after the new run made its own takes the old one', () {
      final t = SimTable(humans: 2, seed: 58, crypto: crypto, traces: true);
      t.start();
      // Seat 0's shuffle, sent and not yet at the referee.
      bool shuffling() => t.lines[0].inFlight.any((e) => e.kind == EventKind.deal && e.round == 1 && e.hand == 1);
      expect(t.clock.runUntil(shuffling, limitMs: 30 * 60000), isTrue);
      // Back at once on a slow line: it reads the log, finds its shuffle
      // owed and makes another, and the old one lands before it.
      t.reload(0, awayMs: 500, lastWordsLandAfterMs: 3000, latencyMs: 1000);
      expect(t.run(), isTrue, reason: t.following.map((c) => c.rules.describe()).join('\n'));
      agree(t);
      expect(t.clients.first.rules.removals, isEmpty);
      expect(t.trace.where((l) => l.contains('p0: an earlier run\'s step for seat 0')), isNotEmpty,
          reason: 'the new run made its own shuffle before the old one came back');
    });

    group('a lie', () {
      test('saying the lead card is nowhere gives the hand up and the liar their seat', () {
        final t = SimTable(humans: 2, seed: 61, crypto: crypto, conducts: {0: Lie.declare});
        t.start();
        expect(t.clock.runUntil(() => t.clients[1].started && t.clients[1].rules.removals.isNotEmpty, limitMs: 60 * 60000), isTrue,
            reason: 'the liar is found out');
        final honest = t.clients[1].rules;
        expect(honest.removals[0]!.exit, Exit.lied);
        // The liar had the lead card: the hand they lied in is given up.
        final r = honest.removals[0]!;
        expect(honest.game.handNumber, greaterThan(r.hand));
        t.people[0].depart(Going.crash);
        expect(t.run(), isTrue);
        agree(t);
        expect(t.following.first.rules.removals.keys, [0]);
      });

      test('a piece of a departed hand kept back gives the hand up, and the game goes on', () {
        final t = SimTable(humans: 2, seed: 63, crypto: crypto, conducts: {1: Lie.withhold}, traces: true);
        t.people[0]
          ..going = Going.leave
          ..goAt = Moment.midTrick;
        t.start();
        expect(t.run(), isTrue, reason: t.following.map((c) => c.rules.describe()).join('\n'));
        agree(t);
        final r = t.clients[1].rules;
        expect(r.removals.keys, [0]);
        expect(t.trace.where((l) => l.contains('p1: hand ${r.removals[0]!.hand} given up: a departed hand could not be opened')), isNotEmpty);
        expect(r.result?.body['state'], TableState.finished.name, reason: 'a finished game, rated as any');
      });

      test('a pass sealed to nothing is not taken, and the clock has the seat', () {
        final t = SimTable(humans: 2, seed: 62, crypto: crypto, conducts: {0: Lie.seal});
        t.start();
        expect(t.clock.runUntil(() => t.clients[1].started && t.clients[1].rules.removals.isNotEmpty, limitMs: 60 * 60000), isTrue);
        expect(t.clients[1].rules.removals[0]!.exit, Exit.booted);
        t.people[0].depart(Going.crash);
        expect(t.run(), isTrue);
        // The liar took its own pass, unchecked, as no other side did.
        agree(t, except: {'p0'});
      });
    });
  });
}
