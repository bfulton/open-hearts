import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/engine/bot.dart';
import 'package:open_hearts/engine/card.dart';
import 'package:open_hearts/engine/game.dart';
import 'package:open_hearts/engine/rules.dart';

/// Plays [game] to its end with [bot] in every seat, asserting the
/// invariants that must hold at every step. Returns the number of hands.
int playOut(HeartsGame game, Bot bot, {int handLimit = 200}) {
  var hands = 0;
  final played = <Card>{};

  while (game.phase != Phase.gameOver) {
    switch (game.phase) {
      case Phase.passing:
        for (var s = 0; s < seatCount; s++) {
          final hand = game.handOf(s);
          expect(hand.length, 13, reason: 'a deal is 13 cards');
          final pass = bot.choosePass(hand);
          expect(pass.length, passSize);
          expect(pass.toSet().length, passSize, reason: 'no repeats');
          for (final c in pass) {
            expect(hand, contains(c));
          }
          game.setPass(s, pass);
        }
        expect(game.phase, Phase.playing);
        for (var s = 0; s < seatCount; s++) {
          expect(game.handOf(s).length, 13, reason: 'passing conserves cards');
        }
        played.clear();

      case Phase.playing:
        if (game.pendingTrick != null) {
          final done = game.pendingTrick!;
          expect(done.plays.length, seatCount);
          final led = done.plays.first.card.suit;
          final winning = done.plays.firstWhere((p) => p.seat == done.winner);
          expect(winning.card.suit, led, reason: 'only the led suit wins');
          game.collectTrick();
          expect(game.leader, done.winner, reason: 'the winner leads next');
          break;
        }
        final seat = game.currentSeat!;
        final hand = game.handOf(seat);
        final legal = game.legalPlaysFor(seat);
        expect(legal, isNotEmpty, reason: 'there is always a legal play');
        for (final c in legal) {
          expect(hand, contains(c), reason: 'legal plays come from the hand');
        }
        if (game.isFirstTrick && game.trick.isEmpty) {
          expect(legal, [twoOfClubs], reason: 'the 2C leads the hand');
        }
        if (game.trick.isNotEmpty) {
          final led = game.trick.first.card.suit;
          if (hand.any((c) => c.suit == led)) {
            expect(legal.every((c) => c.suit == led), isTrue,
                reason: 'follow suit when you can');
          }
        }
        final view = BotView(
          seat: seat,
          hand: hand,
          trick: game.trick,
          played: played,
          heartsBroken: game.heartsBroken,
          isFirstTrick: game.isFirstTrick,
          taken: game.taken,
        );
        final choice = bot.chooseCard(view, legal);
        expect(legal, contains(choice), reason: 'the bot plays legally');
        game.play(seat, choice);
        played.add(choice);

      case Phase.handOver:
        expect(game.handScores.reduce((a, b) => a + b) % moonPoints, 0);
        for (var s = 0; s < seatCount; s++) {
          expect(game.handOf(s), isEmpty, reason: 'every card was played');
        }
        hands++;
        expect(hands, lessThan(handLimit), reason: 'the game must terminate');
        game.nextHand();
        played.clear();

      case Phase.gameOver:
        break;
    }
  }
  return hands + 1;
}

void main() {
  group('dealing', () {
    test('deals four distinct 13-card hands from one deck', () {
      final game = HeartsGame(seed: 7);
      final all = <Card>[];
      for (var s = 0; s < seatCount; s++) {
        expect(game.handOf(s).length, 13);
        all.addAll(game.handOf(s));
      }
      expect(all.toSet().length, 52, reason: 'no card is dealt twice');
    });

    test('a hand comes sorted', () {
      final game = HeartsGame(seed: 7);
      final hand = game.handOf(0);
      expect(hand, orderedEquals(List.of(hand)..sort()));
    });

    test('the same seed deals the same cards', () {
      expect(HeartsGame(seed: 42).handOf(0).map((c) => c.code),
          HeartsGame(seed: 42).handOf(0).map((c) => c.code));
    });
  });

  group('passing', () {
    test('hand 0 passes left, and the cards land with the next seat', () {
      final game = HeartsGame(seed: 3);
      expect(game.passDirection, PassDirection.left);
      final sent = [for (var s = 0; s < seatCount; s++) game.handOf(s).take(3).toList()];
      for (var s = 0; s < seatCount; s++) {
        game.setPass(s, sent[s]);
      }
      expect(game.phase, Phase.playing);
      for (var s = 0; s < seatCount; s++) {
        final to = (s + 1) % seatCount;
        expect(game.handOf(to), containsAll(sent[s]));
        expect(game.receivedBy(to), sent[s]);
      }
    });

    test('a card is not passed and received in the same swap', () {
      // Seat 0 passes to seat 1 while seat 3 passes to seat 0: seat 0's
      // outgoing cards must be gone before seat 3's arrive.
      final game = HeartsGame(seed: 11);
      final out = game.handOf(0).take(3).toList();
      for (var s = 0; s < seatCount; s++) {
        game.setPass(s, game.handOf(s).take(3).toList());
      }
      for (final c in out) {
        expect(game.handOf(0).contains(c), isFalse,
            reason: '$c should have left seat 0');
      }
      expect(game.handOf(0).length, 13);
    });

    test('passerTo runs the rotation backwards', () {
      // Passing left means seat s gives to s+1, so seat 0 is receiving
      // from seat 3 — the player drawn on the right.
      final game = HeartsGame(seed: 3);
      expect(game.passDirection, PassDirection.left);
      expect(game.passerTo(0), 3);
      expect(game.passerTo(1), 0);
      for (var s = 0; s < seatCount; s++) {
        final giver = game.passerTo(s);
        expect((giver + game.passDirection.seatOffset) % seatCount, s,
            reason: 'passerTo inverts the offset');
      }
    });

    test('the fourth hand holds and goes straight to play', () {
      var game = HeartsGame(seed: 5);
      final bot = Bot(random: Random(5));
      for (var h = 0; h < 3; h++) {
        expect(game.phase, Phase.passing, reason: 'hand $h passes');
        for (var s = 0; s < seatCount; s++) {
          game.setPass(s, bot.choosePass(game.handOf(s)));
        }
        _finishHandQuickly(game, bot);
        if (game.phase == Phase.gameOver) {
          game = HeartsGame(seed: 5 + h); // extremely unlikely; keep going
          continue;
        }
        game.nextHand();
      }
      expect(game.passDirection, PassDirection.hold);
      expect(game.phase, Phase.playing, reason: 'a hold hand skips passing');
      expect(game.receivedBy(0), isEmpty);
    });

    test('rejects a pass that is not three distinct cards from the hand', () {
      final game = HeartsGame(seed: 9);
      final hand = game.handOf(0);
      expect(() => game.setPass(0, hand.take(2).toList()), throwsArgumentError);
      expect(() => game.setPass(0, [hand[0], hand[0], hand[1]]),
          throwsArgumentError);
      final notMine = Card.deck.firstWhere((c) => !hand.contains(c));
      expect(() => game.setPass(0, [hand[0], hand[1], notMine]),
          throwsArgumentError);
    });
  });

  group('playing', () {
    test('the 2 of clubs leads the first trick', () {
      final game = _dealt(seed: 21);
      expect(game.legalPlaysFor(game.currentSeat!), [twoOfClubs]);
    });

    test('an out-of-turn play throws', () {
      final game = _dealt(seed: 21);
      final wrong = (game.currentSeat! + 1) % seatCount;
      expect(() => game.play(wrong, game.handOf(wrong).first),
          throwsStateError);
    });

    test('an illegal card throws rather than being quietly allowed', () {
      final game = _dealt(seed: 21);
      final seat = game.currentSeat!;
      final bad = game.handOf(seat).firstWhere((c) => c != twoOfClubs);
      expect(() => game.play(seat, bad), throwsArgumentError);
    });

    test('a finished trick waits to be collected', () {
      final game = _dealt(seed: 21);
      final bot = Bot(random: Random(1));
      for (var i = 0; i < seatCount; i++) {
        final seat = game.currentSeat!;
        game.play(seat, bot.chooseCard(_view(game, seat), game.legalPlaysFor(seat)));
      }
      expect(game.currentSeat, isNull, reason: 'the table is waiting');
      expect(game.pendingTrick, isNotNull);
      expect(game.tricksPlayed, 0, reason: 'not swept yet');
      game.collectTrick();
      expect(game.tricksPlayed, 1);
      expect(game.currentSeat, game.leader);
    });

    test('the trick winner takes its points and leads the next', () {
      final game = _dealt(seed: 33);
      final bot = Bot(random: Random(2));
      for (var i = 0; i < seatCount; i++) {
        final seat = game.currentSeat!;
        game.play(seat, bot.chooseCard(_view(game, seat), game.legalPlaysFor(seat)));
      }
      final done = game.pendingTrick!;
      final points = pointsIn(done.plays.map((p) => p.card));
      game.collectTrick();
      expect(game.taken[done.winner], points);
      expect(game.leader, done.winner);
    });
  });

  group('full games', () {
    test('200 seeded games finish, obeying every rule along the way', () {
      for (var seed = 0; seed < 200; seed++) {
        final game = HeartsGame(seed: seed);
        final bot = Bot(random: Random(seed));
        final hands = playOut(game, bot);
        expect(hands, greaterThanOrEqualTo(4),
            reason: 'reaching $gameOverScore takes several hands');
        expect(game.totals.any((t) => t >= gameOverScore), isTrue);
        expect(game.winners, isNotEmpty);
        final low = game.totals.reduce(min);
        for (final w in game.winners) {
          expect(game.totals[w], low);
        }
      }
    });

    test('every hand puts exactly 26 points on the board', () {
      final game = HeartsGame(seed: 1234);
      final bot = Bot(random: Random(1234));
      var checked = 0;
      while (game.phase != Phase.gameOver) {
        if (game.phase == Phase.handOver) {
          expect(game.taken.reduce((a, b) => a + b), moonPoints);
          checked++;
          game.nextHand();
          continue;
        }
        _step(game, bot);
      }
      expect(game.taken.reduce((a, b) => a + b), moonPoints);
      expect(checked, greaterThan(0));
    });

    test('totals only ever move by a legal hand score', () {
      final game = HeartsGame(seed: 99);
      final bot = Bot(random: Random(99));
      var previous = List.of(game.totals);
      while (game.phase != Phase.gameOver) {
        if (game.phase == Phase.handOver) {
          final delta = [
            for (var s = 0; s < seatCount; s++) game.totals[s] - previous[s],
          ];
          expect(delta, game.handScores);
          expect(delta.reduce((a, b) => a + b) % moonPoints, 0);
          previous = List.of(game.totals);
          game.nextHand();
          continue;
        }
        _step(game, bot);
      }
    });
  });
}

/// Deals and gets past passing, so a test can start on trick one.
HeartsGame _dealt({required int seed}) {
  final game = HeartsGame(seed: seed);
  final bot = Bot(random: Random(seed));
  if (game.phase == Phase.passing) {
    for (var s = 0; s < seatCount; s++) {
      game.setPass(s, bot.choosePass(game.handOf(s)));
    }
  }
  return game;
}

BotView _view(HeartsGame game, int seat) => BotView(
      seat: seat,
      hand: game.handOf(seat),
      trick: game.trick,
      played: const {},
      heartsBroken: game.heartsBroken,
      isFirstTrick: game.isFirstTrick,
      taken: game.taken,
    );

/// One engine step: settle the pass, sweep a finished trick, or play the
/// seat on turn.
void _step(HeartsGame game, Bot bot) {
  if (game.phase == Phase.passing) {
    for (var s = 0; s < seatCount; s++) {
      game.setPass(s, bot.choosePass(game.handOf(s)));
    }
    return;
  }
  if (game.pendingTrick != null) {
    game.collectTrick();
    return;
  }
  final seat = game.currentSeat!;
  game.play(seat, bot.chooseCard(_view(game, seat), game.legalPlaysFor(seat)));
}

/// Plays the current hand out, stopping at [Phase.handOver].
void _finishHandQuickly(HeartsGame game, Bot bot) {
  while (game.phase == Phase.playing) {
    _step(game, bot);
  }
}
