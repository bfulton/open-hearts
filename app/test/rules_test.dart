import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/engine/card.dart';
import 'package:open_hearts/engine/rules.dart';

List<Card> cards(String codes) =>
    codes.split(' ').where((s) => s.isNotEmpty).map(Card.parse).toList();

void main() {
  group('Card', () {
    test('notation round-trips', () {
      for (final c in Card.deck) {
        expect(Card.parse(c.code), same(c));
      }
    });

    test('is interned, so equality is identity', () {
      expect(Card.parse('QS'), same(queenOfSpades));
      expect(Card.of(Suit.clubs, Rank.two), same(twoOfClubs));
      expect(Card.deck.toSet().length, 52);
    });

    test('parse rejects nonsense', () {
      expect(() => Card.parse('1S'), throwsFormatException);
      expect(() => Card.parse('QX'), throwsFormatException);
      expect(() => Card.parse('S'), throwsFormatException);
    });

    test('sorts by suit then rank', () {
      final hand = cards('AH 2C QS 10D 3C')..sort();
      expect(hand.map((c) => c.code).toList(),
          ['2C', '3C', '10D', 'QS', 'AH']);
    });
  });

  group('points', () {
    test('hearts are 1, the queen is 13, everything else is 0', () {
      expect(cardPoints(Card.parse('2H')), 1);
      expect(cardPoints(Card.parse('AH')), 1);
      expect(cardPoints(queenOfSpades), 13);
      expect(cardPoints(Card.parse('AS')), 0);
      expect(cardPoints(Card.parse('KS')), 0);
      expect(cardPoints(Card.parse('QH')), 1);
      expect(cardPoints(Card.parse('QD')), 0);
    });

    test('a whole deck is exactly the moon', () {
      expect(pointsIn(Card.deck), moonPoints);
    });
  });

  group('trickWinner', () {
    test('highest of the led suit takes it', () {
      final trick = [
        Play(0, Card.parse('5C')),
        Play(1, Card.parse('KC')),
        Play(2, Card.parse('7C')),
        Play(3, Card.parse('2C')),
      ];
      expect(trickWinner(trick), 1);
    });

    test('an off-suit card cannot win, however high', () {
      final trick = [
        Play(0, Card.parse('5C')),
        Play(1, Card.parse('AS')),
        Play(2, Card.parse('AH')),
        Play(3, Card.parse('6C')),
      ];
      expect(trickWinner(trick), 3);
    });

    test('the leader wins when nobody follows', () {
      final trick = [
        Play(2, Card.parse('3D')),
        Play(3, Card.parse('AS')),
        Play(0, Card.parse('KH')),
        Play(1, Card.parse('AC')),
      ];
      expect(trickWinner(trick), 2);
    });
  });

  group('legalPlays', () {
    List<String> legal({
      required String hand,
      String trick = '',
      bool heartsBroken = false,
      bool isFirstTrick = false,
    }) {
      final plays = <Play>[];
      for (final c in cards(trick)) {
        plays.add(Play(plays.length, c));
      }
      return legalPlays(
        hand: cards(hand),
        trick: plays,
        heartsBroken: heartsBroken,
        isFirstTrick: isFirstTrick,
      ).map((c) => c.code).toList()
        ..sort();
    }

    test('the first trick is led with the 2 of clubs and nothing else', () {
      expect(legal(hand: '2C 5C AH QS', isFirstTrick: true), ['2C']);
    });

    test('you must follow suit', () {
      expect(legal(hand: '2C 9C AH QS', trick: '5C'), ['2C', '9C']);
    });

    test('void in the led suit frees the whole hand', () {
      expect(legal(hand: '2D 9H QS', trick: '5C'), ['2D', '9H', 'QS']);
    });

    test('hearts may not be led until broken', () {
      expect(legal(hand: '2D 9H QS'), ['2D', 'QS']);
    });

    test('once broken, hearts lead like anything else', () {
      expect(legal(hand: '2D 9H QS', heartsBroken: true), ['2D', '9H', 'QS']);
    });

    test('a hand of nothing but hearts leads a heart, broken or not', () {
      expect(legal(hand: '2H 9H AH'), ['2H', '9H', 'AH']);
    });

    test('no points on the first trick when void in clubs', () {
      expect(legal(hand: '2D 9H QS', trick: '5C', isFirstTrick: true), ['2D']);
    });

    test('the first-trick ban yields when points are all you hold', () {
      expect(legal(hand: '2H QS AH', trick: '5C', isFirstTrick: true),
          ['2H', 'AH', 'QS']);
    });

    test('following suit outranks the first-trick ban', () {
      // Holding a club, the club must be played — the ban never comes up.
      expect(legal(hand: '9C QS AH', trick: '5C', isFirstTrick: true), ['9C']);
    });
  });

  group('scoreHand', () {
    test('ordinary hands score as taken', () {
      expect(scoreHand([13, 5, 8, 0]), [13, 5, 8, 0]);
    });

    test('a shot moon scores the shooter nothing and everyone else 26', () {
      expect(scoreHand([0, 26, 0, 0]), [26, 0, 26, 26]);
    });

    test('25 is not the moon', () {
      expect(scoreHand([25, 1, 0, 0]), [25, 1, 0, 0]);
    });
  });

  group('PassDirection', () {
    test('cycles left, right, across, hold', () {
      expect(
          [for (var h = 0; h < 8; h++) PassDirection.forHand(h).name],
          ['left', 'right', 'across', 'hold',
           'left', 'right', 'across', 'hold']);
    });

    test('left is the seat that plays next', () {
      expect(PassDirection.left.seatOffset, 1);
      expect(PassDirection.across.seatOffset, 2);
      expect(PassDirection.right.seatOffset, 3);
      expect(PassDirection.hold.seatOffset, 0);
    });
  });

  group('lowestTotals', () {
    test('picks the low score', () {
      expect(lowestTotals([50, 12, 101, 30]), [1]);
    });

    test('reports a tie as a tie', () {
      expect(lowestTotals([12, 12, 101, 30]), [0, 1]);
    });
  });
}
