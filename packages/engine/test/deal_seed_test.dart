/// A solo game's deal (deal_seed.dart): the generator against answers
/// computed elsewhere, the draw that keeps it fair, and the deals
/// themselves counted for bias.
library;

import 'package:engine/engine.dart';
import 'package:test/test.dart';

/// The seed the known answers are for: the bytes 0 to 31.
final _counting = DealSeed([for (var i = 0; i < 32; i++) i]);

void main() {
  group('known answers', () {
    // Computed by a dozen lines of Python with nothing but hmac and
    // hashlib, from the description in docs/explanation/fair-deal.md — not from
    // this code — and the same on the VM and in a browser.
    test('the stream is HMAC-SHA-256 of the seed over "deal", the hand and the block', () {
      final hand0 = DealStream(_counting, 0);
      expect([for (var i = 0; i < 10; i++) hand0.nextWord()],
          [2870744125, 3641550150, 3153617081, 3665956095, 2965357317, 136136, 3734734121, 66543994, 1477042840, 1166673613],
          reason: 'eight words to a block, and the ninth from the next');
      final hand7 = DealStream(_counting, 7);
      expect([for (var i = 0; i < 3; i++) hand7.nextWord()], [1313806791, 1207577329, 3528217364]);
    });

    test('a hand\'s deck is the stream\'s Fisher–Yates of the deck in index order', () {
      expect(_counting.deck(0).map((c) => c.code).join(' '),
          '4C 6C AH AS 6D 8H 3D 3C 2C 9C 10C QH KC 7D 5D 2S QS KS JD 3S JH 2D 6S 7C 5S 6H '
          '5H 2H JS 4S AC 7H 10S 9S QD 4D 8S 3H QC 5C 9H KH 10H 9D 8D JC KD 10D AD 7S 8C 4H');
      expect(_counting.deck(1).map((c) => c.code).join(' '),
          '7D 4D 8H 8D 6D 5S 9S 8C JH 10C KC JD KH 10D 8S AC 9C AD QC 5D 6C KD 3H 10S 7S 2S '
          '2H 2D AS 2C QS KS 6S 4S 3C 4H 7C QD 5H 10H AH JC 3D 9D 6H JS 5C QH 9H 3S 7H 4C');
    });

    test('a game dealt from the seed holds those decks, thirteen a seat', () {
      final game = HeartsGame(dealSeed: _counting);
      expect([for (var s = 0; s < seatCount; s++) game.handOf(s).map((c) => c.code).join(' ')], [
        '2C 3C 4C 6C 9C 10C KC 3D 6D AS 8H QH AH',
        '7C 2D 5D 7D JD 2S 3S 5S 6S QS KS 6H JH',
        'QC AC 4D QD 4S 8S 9S 10S JS 2H 3H 5H 7H',
        '5C 8C JC 8D 9D 10D KD AD 7S 4H 9H 10H KH',
      ]);
      // The second hand is dealt from its own stream, not the first's
      // carried on.
      _playHand(game);
      game.nextHand();
      final deck = _counting.deck(1);
      for (var s = 0; s < seatCount; s++) {
        expect(game.handOf(s), deck.sublist(s * 13, s * 13 + 13)..sort());
      }
    });

    test('an int seed deals by Random, exactly as pinned', () {
      // The first hand of four int seeds, the largest a full 31 bits:
      // what an `oh1` record replays from.
      expect(HeartsGame(seed: 42).dealSeed, isNull);
      final before = {
        0: [
          '4C 5C 7C 9C 10D KD 2S 4S 9S 10S AS 2H 9H',
          '6C 8C 10C KC 2D 7D 8D QD 5S JS QS 3H QH',
          '2C QC AC 4D 5D JD 3S KS 5H 6H 7H 10H KH',
          '3C JC 3D 6D 9D AD 6S 7S 8S 4H 8H JH AH',
        ],
        1: [
          '4C 7C 10C AC 5D QD 2S 3S 8S QS 2H 4H KH',
          '2C 3C 9C 4D JD 6S 9S JS KS 5H 9H QH AH',
          '5C 6C 8C KC 6D 7D 9D AD 5S 7S AS 7H 10H',
          'JC QC 2D 3D 8D 10D KD 4S 10S 3H 6H 8H JH',
        ],
        42: [
          '2D 9D JD AD 4S 6S 7S 8S KS 2H 4H 9H AH',
          '3C 8C 9C 10C JC AC 5D 6D 10S JS AS 6H JH',
          '2C 4C 5C KC 3D QD 2S 3S 9S QS 5H 8H QH',
          '6C 7C QC 4D 7D 8D 10D KD 5S 3H 7H 10H KH',
        ],
        2147483647: [
          '2C 7C 10C 3D 6D 2S 6S 8S KS 2H 5H 7H 9H',
          '6C QC 4D 7D 9D 10D JD 4S 7S JS 8H 10H AH',
          '3C 5C JC AC 2D 5D KD 3S 5S 3H 6H JH QH',
          '4C 8C 9C KC 8D QD AD 9S 10S QS AS 4H KH',
        ],
      };
      for (final MapEntry(key: seed, value: hands) in before.entries) {
        final game = HeartsGame(seed: seed);
        expect([for (var s = 0; s < seatCount; s++) game.handOf(s).map((c) => c.code).join(' ')], hands, reason: 'seed $seed');
      }
    });
  });

  group('the draw', () {
    test('a word from the uneven top is thrown away, and the next one drawn', () {
      // 2³² mod 52 is 48: the top 48 words would make 0..47 likelier
      // than 48..51.
      const limit = 0x100000000 - 48;
      final words = [0xffffffff, limit, limit - 1, 5];
      var i = 0;
      expect(uniformBelow(52, () => words[i++]), (limit - 1) % 52);
      expect(i, 3, reason: 'two words thrown away, the third taken');
      expect(uniformBelow(52, () => words[i++]), 5);
      // A power of two divides 2³² and throws nothing away.
      i = 0;
      expect(uniformBelow(4, () => words[i++]), 3);
      expect(i, 1);
      expect(() => uniformBelow(0, () => 0), throwsRangeError);
    });

    test('every order of four is as likely as every other', () {
      // The whole permutation, not just where each card lands: a
      // shuffle that swaps every position with any other reaches
      // 4⁴ = 256 equally likely paths, which 24 orders cannot share
      // evenly. Twenty-four thousand shuffles, a thousand expected
      // each; a χ² of 23 degrees of freedom passes 71 about once in a
      // million.
      final seen = <String, int>{};
      for (var h = 0; h < 24000; h++) {
        final order = DealStream(_counting, h).shuffle(const [0, 1, 2, 3]).join();
        seen[order] = (seen[order] ?? 0) + 1;
      }
      expect(seen.length, 24);
      expect(_chi(seen.values, 1000), lessThan(71));
    });

    test('every card is as likely in every position: 20,000 deals, χ² over 52 × 52', () {
      // For uniformly random deals the statistic is 52/51 of a χ² with
      // 51² degrees of freedom: about 2,652, give or take 74. The bound
      // is six of those above. A fixed seed, so the test is the same
      // every run; the controls below are the same count over two
      // shuffles that are wrong, and it catches both.
      const deals = 20000;
      final fair = _positions(deals, (h) => _counting.deck(h));
      expect(fair, lessThan(3100));

      // Every position swapped with any of the 52: the classic mistake.
      final naive = _positions(deals, (h) {
        final s = DealStream(_counting, h);
        final deck = List.of(Card.deck);
        for (var i = 51; i >= 0; i--) {
          final j = s.below(52);
          final t = deck[i];
          deck[i] = deck[j];
          deck[j] = t;
        }
        return deck;
      });
      expect(naive, greaterThan(3100));

      // Each draw from one byte, taken modulo with no rejection.
      final modulo = _positions(deals, (h) {
        final s = DealStream(_counting, h);
        final deck = List.of(Card.deck);
        for (var i = 51; i > 0; i--) {
          final j = (s.nextWord() & 0xff) % (i + 1);
          final t = deck[i];
          deck[i] = deck[j];
          deck[j] = t;
        }
        return deck;
      });
      expect(modulo, greaterThan(3100));
    });
  });

  group('the seed', () {
    test('is 64 hex digits in a record, and reads back', () {
      expect(_counting.hex, '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
      expect(DealSeed.tryParse(_counting.hex), _counting);
      expect(DealSeed.tryParse(_counting.hex.toUpperCase()), _counting);
      expect(DealSeed.tryParse(_counting.hex.substring(2)), isNull, reason: 'short');
      expect(DealSeed.tryParse('${_counting.hex}00'), isNull, reason: 'long');
      expect(DealSeed.tryParse('${_counting.hex.substring(1)}g'), isNull, reason: 'not hex');
      expect(DealSeed.tryParse('+${_counting.hex.substring(1)}'), isNull, reason: 'not hex either');
      expect(() => DealSeed(const [1, 2, 3]), throwsArgumentError);
    });

    test('is drawn fresh for every game that deals itself without one', () {
      final a = DealSeed.draw();
      final b = DealSeed.draw();
      expect(a.bytes.length, DealSeed.length);
      expect(a, isNot(b));
      expect(HeartsGame().dealSeed, isNotNull);
      expect(HeartsGame().dealSeed, isNot(HeartsGame().dealSeed));
      expect(HeartsGame(sealed: true).dealSeed, isNull, reason: 'a sealed game\'s cards come from the deal');
      expect(() => HeartsGame(seed: 1, dealSeed: a), throwsArgumentError);
    });
  });
}

/// Pearson's statistic over card-by-position counts of [deals] decks.
double _positions(int deals, List<Card> Function(int hand) deck) {
  final counts = List.filled(52 * 52, 0);
  for (var h = 0; h < deals; h++) {
    final d = deck(h);
    for (var p = 0; p < 52; p++) {
      counts[d[p].index * 52 + p]++;
    }
  }
  return _chi(counts, deals / 52);
}

double _chi(Iterable<int> observed, num expected) {
  var x = 0.0;
  for (final o in observed) {
    x += (o - expected) * (o - expected) / expected;
  }
  return x;
}

/// Plays out the current hand with the plainest bot in every seat.
void _playHand(HeartsGame game) {
  final bot = Bot();
  final played = <Card>{};
  if (game.phase == Phase.passing) {
    for (var s = 0; s < seatCount; s++) {
      game.setPass(s, bot.choosePass(game.handOf(s)));
    }
  }
  while (game.phase == Phase.playing) {
    if (game.pendingTrick != null) {
      game.collectTrick();
      continue;
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
    final card = bot.chooseCard(view, game.legalPlaysFor(seat));
    game.play(seat, card);
    played.add(card);
  }
}
