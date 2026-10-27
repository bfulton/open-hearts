/// People going at a refereed table, every way and at every moment of a
/// hand: by their own leave, the app gone, doing nothing, or off the
/// network. Whoever is left plays the game out; a sealed table opens the
/// departed hand from the escrow — the house's piece and the other
/// person's — and the house holds the seat from the next hand.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart' show Phase;
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// The ways a seat may have been given up, for each way of going. A
/// connection gone is found at the seat's turn, by its silence or its
/// clock, whichever the table reaches first.
const exits = {
  Going.leave: {Exit.left},
  Going.idle: {Exit.booted},
  Going.crash: {Exit.absent, Exit.booted},
  Going.offline: {Exit.absent, Exit.booted},
};

/// Every client still following came to the same table, and it is over
/// as [state] says.
void agree(SimTable t, TableState state) {
  expect(t.lockstepProblems(), isEmpty, reason: 'every side saw the same table after every entry');
  final among = t.following;
  expect(among, isNotEmpty);
  final first = among.first.rules;
  for (final c in among) {
    expect(c.state, state, reason: 'seat ${c.mySeat}');
    expect(c.rules.endN, first.endN, reason: 'seat ${c.mySeat} ended the log where the others did');
    expect(c.rules.endHash, first.endHash);
    expect(c.game.totals, first.game.totals);
    expect({for (final e in c.rules.removals.entries) e.key: e.value.exit}, {for (final e in first.removals.entries) e.key: e.value.exit});
  }
  if (t.spec.sealed) {
    expect(first.result, isNotNull, reason: 'the house said how the game came out');
    expect(first.result!.body['state'], state.name);
  }
}

/// After [seat]'s person went, nobody but the house said anything for
/// the seat: nothing at all in the rest of the hand they went in, at a
/// sealed table, and the house from the next.
void heldAfter(SimTable t, int seat) {
  final rules = t.following.first.rules;
  final r = rules.removals[seat]!;
  final person = t.signers[seat].publicKey;
  for (final e in rules.taken) {
    if (!{EventKind.deal, EventKind.pass, EventKind.play}.contains(e.kind) || e.seat != seat) continue;
    final n = rules.log.indexWhere((l) => l.event?.id == e.id);
    if (n <= r.n) {
      expect(e.author, person, reason: 'before they went, the seat was theirs');
    } else if (t.spec.sealed) {
      expect(e.hand, greaterThan(r.hand), reason: 'nothing is said for the seat in the hand they went in: it is opened');
      expect(e.author, t.houseSigner.publicKey, reason: 'the house holds the seat from the next hand');
    } else {
      fail('a bot seat at an unsealed table is everyone\'s to work out, and says nothing: $e');
    }
  }
}

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  for (final sealed in [false, true]) {
    group(sealed ? 'sealed' : 'unsealed', () {
      for (final going in Going.values) {
        // An unsealed hand is dealt from the seed, all at once.
        for (final at in [for (final m in Moment.all) if (sealed || m != Moment.duringDeal) m]) {
          test('a person going by $going ${at.name} leaves the other to play it out', () {
            final t = SimTable(humans: 2, seed: 11 + Moment.all.indexOf(at), crypto: sealed ? crypto : null);
            t.people[0]
              ..going = going
              ..goAt = at;
            t.start();
            expect(t.run(), isTrue, reason: 'the game plays out:\n${t.following.first.rules.describe()}');
            expect(t.people[0].gone, isTrue, reason: 'the moment came');
            agree(t, TableState.finished);
            final rules = t.following.first.rules;
            expect(rules.removals.keys, [0]);
            expect(exits[going], contains(rules.removals[0]!.exit));
            heldAfter(t, 0);
            t.close();
          });
        }
      }

      test('the last person going ends the game', () {
        final t = SimTable(humans: 1, seed: 31, crypto: sealed ? crypto : null);
        t.people[0]
          ..going = Going.leave
          ..goAt = Moment.midTrick;
        t.start();
        expect(t.run(), isTrue);
        agree(t, TableState.ended);
        t.close();
      });

      test('the last person\'s app gone ends the game at their turn', () {
        final t = SimTable(humans: 1, seed: 32, crypto: sealed ? crypto : null);
        t.people[0]
          ..going = Going.crash
          ..goAt = Moment.offTurn;
        t.start();
        expect(t.run(), isTrue);
        if (sealed) {
          // Nobody is following but the house, which said how it ended.
          final said = [for (final e in t.referee.log) if (e.event?.kind == EventKind.result) e.event!];
          expect(said, hasLength(1));
          expect(said.single.author, t.houseSigner.publicKey);
          expect(said.single.body['state'], TableState.ended.name);
        }
        t.close();
      });

      if (sealed) {
        group('the clocks stop while a departed hand is opened', () {
          // The house a long way off: its piece of the escrow takes some
          // twenty seconds to come, and every clock waits on it.
          SimTable slowHouse(int seed) => SimTable(humans: 2, seed: seed, crypto: crypto, houseLatencyMs: 10000);

          // Slow over the second hand's pass, and quick over everything
          // else.
          void thinkOverPass(ScriptedHuman p, int ms) => p.client.changes.listen((_) {
                if (p.client.started) p.thinkMs = p.client.game.phase == Phase.passing && p.client.game.handNumber == 1 ? ms : 800;
              });

          bool passOpen(SimTable t) {
            final r = t.clients[1].rules;
            return t.clients[1].started && r.game.handNumber == 1 && r.owed[1]?.turn.isPass == true;
          }

          test('a turn open through it is not lost to the wait', () {
            final t = slowHouse(65);
            thinkOverPass(t.people[0], 60000);
            thinkOverPass(t.people[1], 75000);
            t.start();
            expect(t.clock.runUntil(() => passOpen(t), limitMs: 60 * 60000), isTrue);
            t.people[0].depart(Going.leave);
            final r = t.clients[1].rules;
            expect(t.clock.runUntil(() => r.taken.any((e) => e.kind == EventKind.pass && e.seat == 1 && e.hand == 1), limitMs: 120000), isTrue,
                reason: 'seventy-five seconds over a pass of sixty-five, with the clock stopped for the wait');
            expect(r.removals.keys, [0]);
            // Its seventy-five, less the wait and the pass's twenty free.
            expect(r.banks[1], inInclusiveRange(5000, 15000));
            expect(t.lockstepProblems(), isEmpty);
            t.close();
          });

          test('a move made in it costs the bank only the time before it', () {
            final t = slowHouse(66);
            thinkOverPass(t.people[0], 60000);
            thinkOverPass(t.people[1], 28000);
            t.start();
            expect(t.clock.runUntil(() => passOpen(t), limitMs: 60 * 60000), isTrue);
            t.clock.schedule(25000, () => t.people[0].depart(Going.leave));
            final r = t.clients[1].rules;
            expect(t.clock.runUntil(() => r.taken.any((e) => e.kind == EventKind.pass && e.seat == 1 && e.hand == 1), limitMs: 120000), isTrue);
            expect(r.paused, isTrue, reason: 'taken in the wait');
            // Twenty-five seconds before the clocks stopped, twenty of them free.
            expect(r.banks[1], inInclusiveRange(39500, 40000));
            expect(t.lockstepProblems(), isEmpty);
            t.close();
          });
        });
      }

      // Off the network past the silence, the seat goes; back, the device
      // reads on, and comes to the table everyone else did.
      for (final at in [for (final m in Moment.all) if (sealed || m != Moment.duringDeal) m]) {
        test('a phone off the network past the silence ${at.name}, and back, follows the table', () {
          final t = SimTable(humans: 2, seed: 11 + Moment.all.indexOf(at), crypto: sealed ? crypto : null);
          t.people[0]
            ..going = Going.offline
            ..goAt = at
            ..backAfterMs = t.spec.timing.silenceMs + 15000;
          t.start();
          expect(t.run(), isTrue, reason: t.following.map((c) => c.rules.describe()).join('\n'));
          expect(t.people[0].goneAtHand, isNotNull, reason: 'the moment came');
          expect(t.following, hasLength(2), reason: 'both devices read the log to the end');
          agree(t, TableState.finished);
          expect(exits[Going.offline], contains(t.clients[1].rules.removals[0]?.exit));
          t.close();
        });
      }

      test('a phone off the network for less than the silence keeps its seat', () {
        final t = SimTable(humans: 2, seed: 33, crypto: sealed ? crypto : null);
        t.people[0]
          ..going = Going.offline
          ..goAt = Moment.onOwnTurn
          ..backAfterMs = t.spec.timing.silenceMs ~/ 2;
        t.start();
        expect(t.run(), isTrue);
        agree(t, TableState.finished);
        expect(t.following.first.rules.removals, isEmpty);
        expect(t.referee.log.where((e) => e.down == t.signers[0].publicKey), isNotEmpty, reason: 'the referee saw it go');
        t.close();
      });
    });
  }
}
