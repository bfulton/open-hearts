import 'dart:math';

import 'package:engine/engine.dart';
import 'package:test/test.dart';

List<Card> cards(String codes) =>
    codes.split(' ').where((s) => s.isNotEmpty).map(Card.parse).toList()..sort();

/// Plays as written, seat by seat from [first].
List<Play> plays(int first, String codes) {
  final cs = codes.split(' ').where((s) => s.isNotEmpty).map(Card.parse).toList();
  return [for (var i = 0; i < cs.length; i++) Play((first + i) % 4, cs[i])];
}

PlaysItself? why(
  String hand, {
  List<Play> trick = const [],
  bool toPlay = true,
  List<Play> lastTrick = const [],
  int pointsTaken = 0,
}) =>
    whyHandPlaysItself(
      hand: cards(hand),
      trick: trick,
      toPlay: toPlay,
      seat: 0,
      lastTrick: lastTrick,
      pointsTaken: pointsTaken,
    );

void main() {
  group('no points left', () {
    test('all 26 taken: whatever is held', () {
      expect(why('2C 9D JS', pointsTaken: 26, toPlay: false), PlaysItself.noPointsLeft);
    });

    test('25 taken is not all of them', () {
      expect(why('2C 9D JS', pointsTaken: 25), isNull);
    });
  });

  group('one-suit run', () {
    test('6-7-8 of clubs', () {
      expect(why('6C 7C 8C', toPlay: false), PlaysItself.oneSuitRun);
    });

    test('two hearts side by side', () {
      expect(why('9H 10H'), PlaysItself.oneSuitRun);
    });

    test('a run that tops its suit, and one at the bottom', () {
      expect(why('QD KD AD', toPlay: false), PlaysItself.oneSuitRun);
      expect(why('2C 3C 4C 5C', toPlay: false), PlaysItself.oneSuitRun);
    });

    test('K-A of spades, the queen not among them', () {
      expect(why('KS AS', toPlay: false), PlaysItself.oneSuitRun);
    });

    test('a gap is not a run', () {
      expect(why('6C 8C', toPlay: false), isNull);
      expect(why('6C 7C 9C', toPlay: false), isNull);
    });

    test('the queen of spades in a run is not interchangeable', () {
      expect(why('JS QS', toPlay: false), isNull);
      expect(why('QS KS', toPlay: false), isNull);
      expect(why('JS QS KS', toPlay: false), isNull);
    });

    test('two suits is not a run', () {
      expect(why('8C 9D', toPlay: false), isNull);
    });
  });

  group('unbeatable', () {
    test('leading with the top of two suits', () {
      expect(why('AC KC AH'), PlaysItself.unbeatable);
    });

    test('following a suit it holds', () {
      expect(why('AC KC AH', trick: plays(1, '5H 2H')), PlaysItself.unbeatable);
      expect(why('AC KC AH', trick: plays(3, '10C')), PlaysItself.unbeatable);
    });

    test('void in the suit led: the discard matters', () {
      expect(why('AC KC AH', trick: plays(1, '5D')), isNull);
    });

    test('a king without its ace is beatable', () {
      expect(why('KS AH'), isNull);
      expect(why('AC QC AH'), isNull); // the K♣ is out there
    });

    test('only judged on the player\'s turn', () {
      expect(why('AC KC AH', toPlay: false), isNull);
    });

    test('A-K-Q of spades holds: the player takes the queen whatever', () {
      expect(why('AS KS QS AD'), PlaysItself.unbeatable);
    });
  });

  group('shown out', () {
    test('led and nobody followed, and that suit is all that is left', () {
      final last = plays(0, '9D 4C QS 7H');
      expect(why('2D 5D 10D', lastTrick: last, toPlay: false), PlaysItself.shownOut);
    });

    test('someone followed', () {
      final last = plays(0, '9D 4C 3D 7H');
      expect(why('2D 5D 10D', lastTrick: last), isNull);
    });

    test('led by someone else', () {
      final last = plays(1, '9D 4C QS 7H'); // seat 1 led, seat 0 played last
      expect(why('2D 5D 10D', lastTrick: last), isNull);
    });

    test('another suit still held', () {
      final last = plays(0, '9D 4C QS 7H');
      expect(why('2D 5D 10S', lastTrick: last), isNull);
    });
  });

  group('fewer than two cards', () {
    test('one card is never offered', () {
      expect(why('AC', pointsTaken: 26), isNull);
      expect(why('AC'), isNull);
      expect(why('9D', lastTrick: plays(0, '2D 4C QS 7H')), isNull);
      expect(why(''), isNull);
    });
  });

  group('autoPlayCard', () {
    test('the rightmost legal card in the hand as drawn', () {
      final hand = cards('2C 9C 3D AD 5H');
      expect(autoPlayCard(hand, cards('2C 9C')), Card.parse('9C'));
      expect(autoPlayCard(hand, hand), Card.parse('5H'));
    });
  });

  // Each reason, checked against the game itself: from wherever the
  // judgement first says a hand plays itself, the player plays it out
  // several ways — always rightmost, always leftmost, at random — and
  // every way must end the hand with the same points in the same
  // places. The others play by a rule that reads only their own hand
  // and the suit led, so any difference is the player's doing; and
  // against the roster's bots, which read the cards played. For the
  // run that second half is the roster's doing as much as the rule's:
  // the player's choices there are equivalent, but someone reading the
  // played cards could in principle answer the 7♣ differently from
  // the 6♣. The roster does not.
  group('the reasons hold in play', () {
    /// One hand of deal [deal], the player playing at random until
    /// [target] is the judgement, and then by [variant]: what each seat
    /// took, and whether [target] ever came up.
    ({List<int> taken, bool settled}) playOut(int deal, int variant, {required bool bots, required PlaysItself target}) {
      final game = HeartsGame(seed: deal);
      final roster = [for (var s = 0; s < seatCount; s++) Bot(persona: Persona.roster[(deal + s) % Persona.roster.length])];
      for (var s = 0; s < seatCount; s++) {
        if (game.phase == Phase.passing) game.setPass(s, roster[s].choosePass(game.handOf(s)));
      }
      final before = Random(deal);
      final after = Random(deal * 31 + variant);
      final played = <Card>{};
      var settled = false;
      while (game.phase == Phase.playing) {
        if (game.pendingTrick != null) {
          game.collectTrick();
          continue;
        }
        final seat = game.currentSeat!;
        final legal = game.legalPlaysFor(seat);
        Card card;
        if (seat == 0) {
          final hand = game.handOf(0);
          settled = settled ||
              whyHandPlaysItself(
                    hand: hand,
                    trick: game.trick,
                    toPlay: true,
                    seat: 0,
                    lastTrick: game.lastTrick,
                    pointsTaken: game.taken.fold(0, (a, b) => a + b),
                  ) ==
                  target;
          card = !settled
              ? (deal.isEven ? legal[before.nextInt(legal.length)] : legal.first)
              : switch (variant) {
                  0 => autoPlayCard(hand, legal),
                  1 => legal.first,
                  _ => legal[after.nextInt(legal.length)],
                };
        } else if (bots) {
          card = roster[seat].chooseCard(
              BotView(
                seat: seat,
                hand: game.handOf(seat),
                trick: game.trick,
                played: played,
                heartsBroken: game.heartsBroken,
                isFirstTrick: game.isFirstTrick,
                taken: game.taken,
              ),
              legal);
        } else {
          card = legal.last; // the highest, by suit then rank
        }
        game.play(seat, card);
        played.add(card);
      }
      return (taken: game.taken, settled: settled);
    }

    for (final bots in [false, true]) {
      for (final target in PlaysItself.values) {
        test('${target.name}, ${bots ? 'against the roster' : 'against a rule that reads nothing'}', () {
          var seen = 0;
          for (var deal = 0; deal < 6000; deal++) {
            final first = playOut(deal, 0, bots: bots, target: target);
            if (!first.settled) continue;
            seen++;
            for (var variant = 1; variant < 4; variant++) {
              expect(playOut(deal, variant, bots: bots, target: target).taken, first.taken,
                  reason: 'deal $deal, variant $variant');
            }
          }
          // Often enough to mean something.
          expect(seen, greaterThan(20));
        });
      }
    }
  });
}
