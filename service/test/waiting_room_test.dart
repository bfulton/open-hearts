/// Strangers seating themselves on the relay, with nobody in charge.
library;

import 'dart:async';
import 'dart:math';

import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

Waiter w(String name, {int rating = 1500, int since = 0}) =>
    Waiter(key: name.padRight(64, '0'), name: name, rating: rating, since: since);

void main() {
  group('the rule', () {
    final rng = Random(1);
    const round = 5000;

    test('four to a table, at random; the remainder waits on', () {
      final p = plan([for (var i = 0; i < 6; i++) w('p$i')], nowMs: 1000, roundMs: round, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 1);
      expect(p.tables.first.length, 4);
      expect(p.leftOver.length, 2);
    });

    test('whoever has waited through a round is seated first', () {
      final old = [w('a', since: 0), w('b', since: 0)];
      final fresh = [for (var i = 0; i < 5; i++) w('f$i', since: 5500)];
      final p = plan([...fresh, ...old], nowMs: 6000, roundMs: round, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 1);
      expect(p.tables.first.map((x) => x.name), containsAll(['a', 'b']));
    });

    test('a table is four ratings within a window that widens with waiting', () {
      final far = [w('lo', rating: 1000), w('hi', rating: 1900), w('a', rating: 1500), w('b', rating: 1520)];
      // First round: 100 points — no four within it.
      expect(plan(far, nowMs: 100, roundMs: round, botsAfterMs: 60000, random: rng).tables, isEmpty);
      // Fifth round: 500 points — still not lo with hi, so no table of four.
      expect(plan(far, nowMs: 21000, roundMs: round, botsAfterMs: 60000, random: rng).tables, isEmpty);
      // Tenth: everyone.
      expect(plan(far, nowMs: 46000, roundMs: round, botsAfterMs: 60000, random: rng).tables.length, 1);
    });

    test('nobody waits past ten seconds: bots take the empty seats, at their rating', () {
      expect(plan([w('solo')], nowMs: 9000, roundMs: round, botsAfterMs: 10000, random: rng).tables, isEmpty);
      final p = plan([w('solo', since: 0), w('near', rating: 1550, since: 8000), w('far', rating: 1900, since: 8000)],
          nowMs: 10000, roundMs: round, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 1);
      expect(p.tables.first.map((x) => x.name), ['solo', 'near']);
      expect(p.leftOver.map((x) => x.name), ['far']);
    });
  });

  group('over the relay', () {
    late Relay relay;
    setUp(() async {
      relay = Relay();
      await relay.serve();
    });
    tearDown(() => relay.close());

    Future<(RelayTransport, WaitingRoom)> join(String name, {int rating = 1500, int target = gameOverScore}) async {
      final s = SchnorrSigner.generate();
      final t = RelayTransport(relays: [relay.url], signer: s, table: poolTag('unrated', target: target));
      await t.ready;
      final room = WaitingRoom(
          relay: t,
          pool: 'unrated',
          target: target,
          name: name,
          rating: rating,
          roundMs: 2000,
          botsAfterMs: 3000,
          heartbeatMs: 500,
          staleMs: 2000);
      return (t, room);
    }

    test('three waiting are seated together by whoever has the lowest key, with one bot', () async {
      final rooms = [for (final n in ['A', 'B', 'C']) await join(n)];
      final specs = await Future.wait(rooms.map((r) => r.$2.seated.first.timeout(const Duration(seconds: 15))));
      expect(specs.map((s) => s.id).toSet().length, 1, reason: 'one table');
      expect(specs.first.seats.whereType<HumanSeat>().length, 3);
      expect(specs.first.seats.whereType<BotSeat>().length, 1);
      expect(specs.first.rated, isFalse);
      for (final r in rooms) {
        r.$2.close();
        r.$1.close();
      }
    });

    test('a game to another score waits in a pool of its own, and the table it gets says so', () async {
      final rooms = [await join('Short'), await join('Long', target: longGameScore)];
      final specs = await Future.wait(rooms.map((r) => r.$2.seated.first.timeout(const Duration(seconds: 15))));
      expect(specs[0].target, gameOverScore);
      expect(specs[1].target, longGameScore);
      expect(specs[0].id, isNot(specs[1].id), reason: 'two games nobody can play at once are two tables');
      for (final spec in specs) {
        expect(spec.seats.whereType<HumanSeat>().length, 1, reason: 'each waited alone and got bots');
      }
      for (final r in rooms) {
        r.$2.close();
        r.$1.close();
      }
    });

    test('if the lowest key falls silent, the next seats the round', () async {
      final rooms = [for (final n in ['A', 'B']) await join(n)];
      rooms.sort((a, b) => a.$2.me.compareTo(b.$2.me));
      // The would-be host leaves without a word.
      rooms.first.$2.close();
      rooms.first.$1.close();
      final spec = await rooms.last.$2.seated.first.timeout(const Duration(seconds: 15));
      expect(spec.seats.whereType<HumanSeat>().map((h) => h.key), [rooms.last.$2.me]);
      expect(spec.seats.whereType<BotSeat>().length, 3);
      rooms.last.$2.close();
      rooms.last.$1.close();
    });
  });
}
