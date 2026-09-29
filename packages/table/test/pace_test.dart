/// A pace, and who it seats you with.
library;

import 'package:table/table.dart';
import 'package:test/test.dart';
import 'dart:math';

Waiter _waiter(String key, {int rating = 1500, int pace = 0, int since = 0}) =>
    Waiter(key: key, name: key, rating: rating, pace: pace, since: since);

void main() {
  group('the pace itself', () {
    test('nothing is known until two hands have been played', () {
      expect(Pace.fresh.known, isFalse);
      expect(Pace.fresh.stated, 0, reason: 'and zero reads as sit me with anybody');
      final one = Pace.fresh.plus(cards: 13, seconds: 65);
      expect(one.known, isFalse, reason: 'one hand is one hand');
      expect(one.secondsPerCard, closeTo(5, 0.01), reason: 'measured all the same');
      final two = one.plus(cards: 13, seconds: 65);
      expect(two.known, isTrue);
      expect(two.stated, 5);
    });

    test('a game folds in whole, and the oldest falls off the end', () {
      var pace = Pace.fresh;
      // Twenty games at ten seconds a card.
      for (var i = 0; i < 20; i++) {
        pace = pace.plus(cards: 13, seconds: 130);
      }
      expect(pace.cards, Pace.remembers, reason: 'it stops counting past what it remembers');
      expect(pace.secondsPerCard, closeTo(10, 0.01));

      // Then somebody gets much faster: within an evening it says so,
      // rather than being held down by a year of old games.
      for (var i = 0; i < 10; i++) {
        pace = pace.plus(cards: 13, seconds: 13);
      }
      expect(pace.secondsPerCard, lessThan(7), reason: 'ten games at one second a card have moved it');
      expect(pace.secondsPerCard, greaterThan(1), reason: 'but not erased what came before');
    });

    test('a pace goes to the device and comes back, and nonsense does not', () {
      final pace = Pace.fresh.plus(cards: 30, seconds: 120);
      final back = Pace.parse(pace.toJson());
      expect(back.secondsPerCard, closeTo(pace.secondsPerCard, 0.0001));
      expect(back.cards, pace.cards);
      expect(Pace.parse(null).known, isFalse);
      expect(Pace.parse({'spc': 'fast', 'cards': 40}).known, isFalse);
      expect(Pace.parse({'spc': 4.0, 'cards': -1}).known, isFalse);
      expect(Pace.parse({'spc': 4.0, 'cards': 99999}).cards, Pace.remembers);
    });

    test('a word for it, for a screen', () {
      expect(Pace.fresh.word, 'not yet known');
      expect(const Pace(secondsPerCard: 2, cards: 40).word, 'brisk');
      expect(const Pace(secondsPerCard: 7, cards: 40).word, 'steady');
      expect(const Pace(secondsPerCard: 15, cards: 40).word, 'unhurried');
      expect(const Pace(secondsPerCard: 40, cards: 40).word, 'slow');
    });

    test('a player who has not measured one is no distance from anybody', () {
      expect(paceApart(0, 30), 0);
      expect(paceApart(30, 0), 0);
      expect(paceApart(3, 30), 27);
      expect(paceApart(5, 5), 0);
    });
  });

  group('seating by pace', () {
    final random = Random(1);

    test('slow players find each other, and the quick ones find each other', () {
      // Eight waiting, all rated alike: four who take a couple of
      // seconds a card and four who take half a minute.
      final waiting = [
        for (var i = 0; i < 4; i++) _waiter('quick$i', pace: 2),
        for (var i = 0; i < 4; i++) _waiter('slow$i', pace: 30),
      ];
      final out = plan(waiting, nowMs: 1000, roundMs: 5000, botsAfterMs: 10000, random: random);
      expect(out.tables, hasLength(2));
      for (final table in out.tables) {
        final paces = table.map((w) => w.pace).toSet();
        expect(paces, hasLength(1), reason: 'a table of one speed: $table');
      }
    });

    test('a rating still decides first: pace does not seat you with somebody far above you', () {
      final waiting = [
        _waiter('me', rating: 1500, pace: 3),
        _waiter('near1', rating: 1520, pace: 25),
        _waiter('near2', rating: 1540, pace: 25),
        _waiter('near3', rating: 1560, pace: 25),
        _waiter('far', rating: 2400, pace: 3),
      ];
      final out = plan(waiting, nowMs: 1000, roundMs: 5000, botsAfterMs: 10000, random: random);
      // Nobody is seated: the three near in rating are far in pace, and
      // the one near in pace is far in rating. Both windows widen.
      expect(out.tables, isEmpty);
      expect(out.leftOver, hasLength(5));
    });

    test('both windows widen with waiting, so nobody is held out of a game by either', () {
      final waiting = [
        _waiter('me', pace: 2, since: 0),
        _waiter('a', pace: 20, since: 0),
        _waiter('b', pace: 21, since: 0),
        _waiter('c', pace: 22, since: 0),
      ];
      expect(plan(waiting, nowMs: 1000, roundMs: 5000, botsAfterMs: 10000, random: random).tables, isEmpty,
          reason: 'eighteen seconds apart in the first round is too far');
      // Half a minute later the window has widened past it.
      final later = [
        _waiter('me', pace: 2, since: 0),
        _waiter('a', pace: 20, since: 0),
        _waiter('b', pace: 21, since: 0),
        _waiter('c', pace: 22, since: 0),
      ];
      final out = plan(later, nowMs: 35000, roundMs: 5000, botsAfterMs: 120000, random: random);
      expect(out.tables, hasLength(1));
      expect(out.tables.first, hasLength(4));
    });

    test('a player who has not measured a pace sits with anybody', () {
      final waiting = [
        _waiter('new', pace: 0),
        _waiter('quick', pace: 2),
        _waiter('slow', pace: 40),
        _waiter('middling', pace: 12),
      ];
      final out = plan(waiting, nowMs: 1000, roundMs: 5000, botsAfterMs: 10000, random: random);
      // The three who know their pace are far apart, so nothing seats;
      // what matters is that the new player was never the reason.
      final newcomer = out.leftOver.where((w) => w.key == 'new');
      expect(newcomer.isEmpty || out.tables.isEmpty, isTrue);
      // With three who agree, the newcomer joins them.
      final withThree = [
        _waiter('new', pace: 0),
        _waiter('a', pace: 12),
        _waiter('b', pace: 12),
        _waiter('c', pace: 13),
      ];
      final seated = plan(withThree, nowMs: 1000, roundMs: 5000, botsAfterMs: 10000, random: random);
      expect(seated.tables, hasLength(1));
      expect(seated.tables.first.map((w) => w.key), contains('new'));
    });

    test('somebody who waited long enough goes with bots, and takes only those who suit them', () {
      final waiting = [
        _waiter('waited', pace: 3, since: 0),
        _waiter('quick', pace: 4, since: 0),
        _waiter('slow', pace: 45, since: 0),
      ];
      final out = plan(waiting, nowMs: 12000, roundMs: 5000, botsAfterMs: 10000, random: random);
      expect(out.tables, hasLength(1));
      final table = out.tables.first.map((w) => w.key).toList();
      expect(table, contains('waited'));
      expect(table, contains('quick'));
      expect(table, isNot(contains('slow')), reason: 'bots are better company than a mismatch');
    });
  });
}
