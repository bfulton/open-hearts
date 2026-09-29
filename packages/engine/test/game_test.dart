import 'dart:math';

import 'package:engine/engine.dart';
import 'package:test/test.dart';

/// Plays [game] to its end with [bot] in every seat, asserting the
/// invariants that must hold at every step. Returns the number of hands.
int playOut(HeartsGame game, Bot bot, {int handLimit = 200, List<List<Card>?> Function()? dealer}) {
  var hands = 0;
  final played = <Card>{};

  while (game.phase != Phase.gameOver) {
    switch (game.phase) {
      case Phase.dealing when dealer != null:
        game.deal(dealer());
        break;
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

      case Phase.dealing:

        throw StateError('a seeded game deals itself');
    }
  }
  return hands + 1;
}

void main() {
  sealedTests();
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
      final bot = Bot();
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
      final bot = Bot();
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
      final bot = Bot();
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
        final bot = Bot();
        final hands = playOut(game, bot);
        expect(hands, greaterThanOrEqualTo(2),
            reason: 'reaching $gameOverScore takes at least two hands: a hand is 26 points at most');
        expect(game.totals.any((t) => t >= gameOverScore), isTrue);
        expect(game.winners, isNotEmpty);
        final low = game.totals.reduce(min);
        for (final w in game.winners) {
          expect(game.totals[w], low);
        }
      }
    });

    test('a game to a hundred is the same game carried on past fifty', () {
      final short = HeartsGame(seed: 3);
      final long = HeartsGame(seed: 3, target: longGameScore);
      final shortHands = playOut(short, Bot());
      final longHands = playOut(long, Bot());
      expect(short.totals.any((t) => t >= gameOverScore), isTrue);
      expect(short.totals.every((t) => t < longGameScore), isTrue);
      expect(long.totals.any((t) => t >= longGameScore), isTrue);
      expect(longHands, greaterThan(shortHands), reason: 'the same deals, and more of them');
    });

    test('every hand puts exactly 26 points on the board', () {
      final game = HeartsGame(seed: 1234);
      final bot = Bot();
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
      final bot = Bot();
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
  final bot = Bot();
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

/// A sealed game: the cards come from outside, and some hands are not
/// this side's to see.
void sealedTests() {
  /// Four hands from a seeded deal, to hand to a sealed game.
  List<List<Card>> handsFrom(int seed) {
    final g = HeartsGame(seed: seed);
    return [for (var s = 0; s < seatCount; s++) g.handOf(s)];
  }

  group('sealed', () {
    test('rests in dealing until dealt, then plays out like any game when every hand is seen', () {
      final game = HeartsGame(sealed: true);
      expect(game.phase, Phase.dealing);
      expect(() => game.setPass(0, []), throwsStateError);
      game.deal(handsFrom(5));
      expect(game.phase, Phase.passing);
      for (var s = 0; s < seatCount; s++) {
        expect(game.knowsHand(s), isTrue);
        expect(game.handSizeOf(s), 13);
      }
      var next = 6;
      expect(playOut(game, Bot(persona: Persona.roster.first), dealer: () => handsFrom(next++)), greaterThan(1));
    });

    test('a seeded game does not take a deal, and a sealed one does not deal twice', () {
      expect(() => HeartsGame(seed: 1).deal(handsFrom(1)), throwsStateError);
      final game = HeartsGame(sealed: true)..deal(handsFrom(1));
      expect(() => game.deal(handsFrom(1)), throwsStateError);
    });

    test('a deal is checked: thirteen a hand, no card twice among the seen', () {
      final hands = handsFrom(2);
      expect(() => HeartsGame(sealed: true).deal([hands[0], hands[1], hands[2]]), throwsArgumentError);
      expect(() => HeartsGame(sealed: true).deal([hands[0].sublist(1), hands[1], hands[2], hands[3]]), throwsArgumentError);
      expect(() => HeartsGame(sealed: true).deal([hands[0], hands[0], null, null]), throwsArgumentError);
    });

    test('a hidden hand has a size and no cards, and its pass may be unknown', () {
      final hands = handsFrom(3);
      final game = HeartsGame(sealed: true)..deal([hands[0], null, hands[2], null]);
      game.declareLeader(hands.indexWhere((h) => h.contains(twoOfClubs)));
      expect(game.knowsHand(1), isFalse);
      expect(() => game.handOf(1), throwsStateError);
      expect(game.handSizeOf(1), 13);
      expect(game.passDirection, PassDirection.left);
      // Seat 1 passes to seat 2, which is seen: its cards must be known.
      expect(() => game.setPass(1, null), throwsArgumentError);
      // Seat 3 passes to seat 0, seen: same. Seat 0 passes to 1, hidden:
      // its cards are seen anyway. Seat 2 passes to 3, hidden.
      game.setPass(0, hands[0].take(3).toList());
      game.setPass(1, hands[1].take(3).toList());
      game.setPass(2, hands[2].take(3).toList());
      game.setPass(3, hands[3].take(3).toList());
      expect(game.phase, Phase.playing);
      expect(game.handSizeOf(1), 13);
      expect(game.handOf(2), containsAll(hands[1].take(3)));
      expect(game.handOf(0), containsAll(hands[3].take(3)));
      expect(game.receivedBy(0), hands[3].take(3).toList());
      expect(game.receivedBy(1), hands[0].take(3).toList(), reason: 'what a seen seat passed is seen, whoever got it');
    });

    test('a pass taken as unknown is filled in before its receiver\'s hand is seen', () {
      final hands = handsFrom(6);
      // Seats 0 and 1 hidden: seat 0's pass to seat 1 is unknown here.
      final game = HeartsGame(sealed: true)..deal([null, null, hands[2], hands[3]]);
      game.declareLeader(hands.indexWhere((h) => h.contains(twoOfClubs)));
      expect(game.passDirection, PassDirection.left);
      game.setPass(0, null);
      expect(() => game.amendPass(1, hands[1].take(3).toList()), throwsStateError, reason: 'seat 1 has not passed');
      // Seat 1 leaves and its hand is opened: not until the pass into
      // it is known.
      expect(() => game.revealHand(1, hands[1]), throwsStateError);
      expect(() => game.amendPass(0, hands[2].take(3).toList()), throwsArgumentError, reason: 'seat 2 holds those');
      expect(() => game.amendPass(0, hands[0].take(2).toList()), throwsArgumentError);
      final passed = hands[0].take(3).toList();
      game.amendPass(0, passed);
      expect(() => game.amendPass(0, passed), throwsStateError, reason: 'known now');
      expect(game.passOf(0), passed);
      game.revealHand(1, hands[1]);
      expect(game.knowsHand(1), isTrue);
      game.setPass(1, hands[1].take(3).toList());
      game.setPass(2, hands[2].take(3).toList());
      game.setPass(3, hands[3].take(3).toList());
      expect(game.phase, Phase.playing);
      expect(game.handOf(1), containsAll(passed));
      expect(game.handOf(1), isNot(contains(hands[1].first)));
      expect(game.receivedBy(1), passed);
      expect(() => game.amendPass(0, passed), throwsStateError, reason: 'the swap has resolved');
    });

    test('a seen seat cannot pass unknown cards, and a hidden seat cannot pass a seen card', () {
      final hands = handsFrom(4);
      final game = HeartsGame(sealed: true)..deal([hands[0], null, null, null]);
      expect(() => game.setPass(0, null), throwsArgumentError);
      expect(() => game.setPass(2, hands[0].take(3).toList()), throwsArgumentError, reason: 'seat 0 holds those');
      expect(game.hasPassed(2), isFalse);
      game.setPass(2, null);
      expect(game.hasPassed(2), isTrue);
      expect(game.passOf(2), isNull);
      expect(() => game.setPass(2, null), throwsStateError);
      // A pass into a seen hand is always known to this side: the seen
      // hand is its own, a bot's or one revealed, none of which takes
      // cards it cannot see.
      expect(() => game.setPass(3, null), throwsArgumentError);
    });

    test('a hand holding the 2♣ unseen needs the leader declared', () {
      final hands = handsFrom(6);
      final holder = hands.indexWhere((h) => h.contains(twoOfClubs));
      final dealt = [for (var s = 0; s < seatCount; s++) s == holder ? null : hands[s]];
      final game = HeartsGame(sealed: true)..deal(dealt);
      for (var s = 0; s < seatCount; s++) {
        if (s != holder) game.setPass(s, hands[s].take(3).toList());
      }
      // The last pass would begin play, and nobody seen holds the 2♣.
      final kept = hands[holder].where((c) => c != twoOfClubs).take(3).toList();
      expect(() => game.setPass(holder, kept), throwsStateError);
      game.declareLeader(holder);
      game.setPass(holder, kept);
      expect(game.phase, Phase.playing);
      expect(game.leader, holder);
    });

    test('a seen hand holding the 2♣ leads whatever was declared', () {
      final hands = handsFrom(6);
      final holder = hands.indexWhere((h) => h.contains(twoOfClubs));
      final game = HeartsGame(sealed: true)
        ..declareLeader((holder + 2) % seatCount)
        ..deal(hands);
      for (var s = 0; s < seatCount; s++) {
        game.setPass(s, hands[s].skip(1).take(3).toList());
      }
      expect(game.leader, holder);
    });

    test('a play from a hidden hand is checked as far as the rules allow, and shrinks it', () {
      final hands = handsFrom(8);
      final holder = hands.indexWhere((h) => h.contains(twoOfClubs));
      final game = HeartsGame(sealed: true)..declareLeader(holder);
      // A hold hand: no pass. Hand 3 holds; deal three hands to get there.
      game.deal([for (var s = 0; s < seatCount; s++) s == holder ? null : hands[s]]);
      expect(game.phase, Phase.passing);
      for (var s = 0; s < seatCount; s++) {
        game.setPass(s, hands[s].where((c) => c != twoOfClubs).take(3).toList());
      }
      expect(game.currentSeat, holder);
      expect(() => game.legalPlaysFor(holder), throwsStateError, reason: 'no hand to list from');
      expect(game.allows(holder, Card.parse('3C')), isFalse, reason: 'the first trick is led with the 2♣');
      expect(game.allows(holder, twoOfClubs), isTrue);
      expect(() => game.play(holder, hands[(holder + 1) % 4].first), throwsArgumentError, reason: 'a seen seat holds that');
      game.play(holder, twoOfClubs);
      expect(game.handSizeOf(holder), 12);
      expect(game.trick.single.card, twoOfClubs);
      // The next seat, seen, must follow; the hidden seat's later
      // plays are taken on trust of the audit: any card not seen elsewhere.
      final next = (holder + 1) % seatCount;
      final clubs = game.handOf(next).where((c) => c.suit == Suit.clubs);
      if (clubs.isNotEmpty) expect(game.legalPlaysFor(next), everyElement(predicate<Card>((c) => c.suit == Suit.clubs)));
    });

    test('a hidden hand can be revealed, once, with as many cards as it holds', () {
      final hands = handsFrom(9);
      final game = HeartsGame(sealed: true)..deal([hands[0], hands[1], hands[2], null]);
      expect(() => game.revealHand(3, hands[3].sublist(1)), throwsArgumentError);
      expect(() => game.revealHand(3, [...hands[3].sublist(1), hands[0].first]), throwsArgumentError);
      game.revealHand(3, hands[3]);
      expect(game.knowsHand(3), isTrue);
      expect(game.handOf(3), orderedEquals(List.of(hands[3])..sort()));
      expect(() => game.revealHand(3, hands[3]), throwsStateError);
      expect(() => game.revealHand(0, hands[0]), throwsStateError);
    });

    test('the next hand of a sealed game waits to be dealt again', () {
      final game = HeartsGame(sealed: true)..deal(handsFrom(10));
      final bot = Bot(persona: Persona.roster.first);
      while (game.phase != Phase.handOver) {
        if (game.phase == Phase.passing) {
          for (var s = 0; s < seatCount; s++) {
            game.setPass(s, bot.choosePass(game.handOf(s)));
          }
        } else if (game.pendingTrick != null) {
          game.collectTrick();
        } else {
          final s = game.currentSeat!;
          game.play(s, game.legalPlaysFor(s).first);
        }
      }
      game.nextHand();
      expect(game.phase, Phase.dealing);
      expect(game.handNumber, 1);
      expect(game.handSizeOf(0), 0);
      game.deal(handsFrom(11));
      expect(game.phase, Phase.passing);
      expect(game.passDirection, PassDirection.right);
    });
  });
}
