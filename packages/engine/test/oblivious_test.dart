import 'dart:math';

import 'package:engine/engine.dart';
import 'package:test/test.dart';

/// Runs [bot] through [games] seeded games and hands every decision it
/// makes to [onPlay] and [onPass] before applying it.
void eachDecision(
  int games,
  void Function(BotView view, List<Card> legal, Card chosen) onPlay,
  void Function(List<Card> hand, List<Card> chosen) onPass,
) {
  for (var seed = 0; seed < games; seed++) {
    final game = HeartsGame(seed: seed);
    final bot = Bot(random: Random(seed));
    final played = <Card>{};
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          for (var s = 0; s < seatCount; s++) {
            final hand = game.handOf(s);
            final pass = bot.choosePass(hand);
            onPass(hand, pass);
            game.setPass(s, pass);
          }
          played.clear();
        case Phase.playing:
          if (game.pendingTrick != null) {
            game.collectTrick();
            break;
          }
          final seat = game.currentSeat!;
          final view = BotView(
            seat: seat,
            hand: game.handOf(seat),
            trick: game.trick,
            played: played,
            heartsBroken: game.heartsBroken,
            isFirstTrick: game.isFirstTrick,
            taken: game.taken,
          );
          final legal = game.legalPlaysFor(seat);
          final card = bot.chooseCard(view, legal);
          onPlay(view, legal, card);
          game.play(seat, card);
          played.add(card);
        case Phase.handOver:
          game.nextHand();
          played.clear();
        case Phase.gameOver:
          break;
      }
    }
  }
}

void main() {
  group('circuit primitives', () {
    test('AND costs one gate only when a secret is involved', () {
      final c = Circuit();
      final s = c.secret(true);
      final p = c.public(true);
      c.and(p, c.public(false));
      expect(c.ands, 0, reason: 'public ∧ public is done in the clear');
      c.and(s, Circuit.one);
      c.and(s, Circuit.zero);
      expect(c.ands, 0, reason: 'constants fold');
      c.and(s, p);
      expect(c.ands, 1);
      c.and(s, c.secret(false));
      expect(c.ands, 2);
      c.xor(s, c.secret(true));
      c.not(s);
      expect(c.ands, 2, reason: 'XOR and NOT are free');
    });

    test('popcount, lt and firstSet compute what they say', () {
      final rng = Random(7);
      for (var n = 0; n < 200; n++) {
        final c = Circuit();
        final bits = [for (var i = 0; i < 13; i++) rng.nextBool()];
        final v = [for (final b in bits) c.secret(b)];
        final count = c.popcount(v, width: 4);
        final expected = bits.where((b) => b).length;
        var got = 0;
        for (var k = 0; k < 4; k++) {
          if (count[k].value) got |= 1 << k;
        }
        expect(got, expected);
        expect(c.ands, 10, reason: '13 bits cost 13 − popcount(13) adders');

        final a = rng.nextInt(128), b = rng.nextInt(128);
        expect(c.lt(c.number(a, 7), c.number(b, 7)).value, a < b);
        final before = c.ands;
        final sa = [for (var k = 0; k < 7; k++) c.secret((a >> k) & 1 == 1)];
        final sb = [for (var k = 0; k < 7; k++) c.secret((b >> k) & 1 == 1)];
        expect(c.lt(sa, sb).value, a < b);
        expect(c.ands - before, 7, reason: 'one AND per bit');

        final first = c.firstSet(v);
        final last = c.lastSet(v);
        final firstIdx = bits.indexOf(true);
        final lastIdx = bits.lastIndexOf(true);
        for (var i = 0; i < 13; i++) {
          expect(first[i].value, i == firstIdx);
          expect(last[i].value, i == lastIdx);
        }
      }
    });
  });

  group('the oblivious bot', () {
    test('agrees with Bot and legalPlays on every decision of 40 games', () {
      var plays = 0, passes = 0;
      int? playGates, passGates, legalGates, positionGates;
      eachDecision(
        40,
        (view, legal, chosen) {
          final lc = Circuit();
          final lb = ObliviousBot(lc);
          final r = lb.legal(lb.secretHand(view.hand), PublicPlay(lc, view));
          expect(ObliviousBot.decodeSet(r.legal), unorderedEquals(legal));
          expect(r.hasFollowing.value,
              view.trick.isNotEmpty && legal.first.suit == view.trick.first.card.suit);
          legalGates ??= lc.ands;
          expect(lc.ands, legalGates, reason: 'the circuit has one shape');

          final c = Circuit();
          final ob = ObliviousBot(c);
          final out = ob.chooseCard(ob.secretHand(view.hand), PublicPlay(c, view));
          expect(ObliviousBot.decode(out), chosen, reason: 'hand ${view.hand} trick ${view.trick}');
          expect(c.secretInputs, 52);
          playGates ??= c.ands;
          expect(c.ands, playGates, reason: 'the circuit has one shape');

          // The same decision over the hand as thirteen dealt positions.
          final pc = Circuit();
          final pb = ObliviousBot(pc);
          // Positions this seat has already opened hold cards it played;
          // the circuit must ignore whatever sits there.
          final gone = view.played.where((c) => !view.hand.contains(c)).toList();
          final positions = [...view.hand, ...gone.take(13 - view.hand.length)]
            ..shuffle(Random(plays));
          expect(positions.length, 13);
          final dealt = [
            for (final card in positions)
              [for (var k = 0; k < 6; k++) pc.secret((card.index >> k) & 1 == 1)],
          ];
          final held = [for (final card in positions) pc.public(view.hand.contains(card))];
          final at = pb.chooseCardAt(dealt, held, PublicPlay(pc, view));
          expect(ObliviousBot.decode(at.chosen), chosen);
          final opened = [for (var k = 0; k < 13; k++) if (at.heldAt[k].value) k];
          expect(opened, [positions.indexOf(chosen)]);
          positionGates ??= pc.ands;
          expect(pc.ands, positionGates, reason: 'the circuit has one shape');
          plays++;
        },
        (hand, chosen) {
          final c = Circuit();
          final ob = ObliviousBot(c);
          final out = ObliviousBot.decodeSet(ob.choosePass(ob.secretHand(hand)));
          expect(out, unorderedEquals(chosen), reason: 'hand $hand');
          passGates ??= c.ands;
          expect(c.ands, passGates, reason: 'the circuit has one shape');
          passes++;
        },
      );
      expect(plays, greaterThan(10000));
      expect(passes, greaterThan(400));
    });

    test('folding the public inputs never changes the answer', () {
      eachDecision(
        5,
        (view, legal, chosen) {
          final c = Circuit(foldPublic: true);
          final ob = ObliviousBot(c);
          final out = ob.chooseCard(ob.secretHand(view.hand), PublicPlay(c, view));
          expect(ObliviousBot.decode(out), chosen);
          expect(c.publicInputs, 0);
        },
        (hand, chosen) {},
      );
    });
  });
}
