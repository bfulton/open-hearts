/// Strangers seating themselves on the relay, with nobody in charge.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

    test('each waiter\'s own wait for people is kept: up to five minutes for a person, or none', () {
      final patient = w('patient')..botsAfterMs = WaitingRoom.personAtMostMs;
      expect(plan([patient], nowMs: 60000, roundMs: round, botsAfterMs: 10000, random: rng).tables, isEmpty,
          reason: 'a minute in, still waiting for a person');
      expect(plan([patient], nowMs: WaitingRoom.personAtMostMs, roundMs: round, botsAfterMs: 10000, random: rng).tables.length, 1,
          reason: 'and at five minutes, bots');
      final eager = w('eager', since: 1000)..botsAfterMs = 0;
      expect(plan([eager], nowMs: 1000, roundMs: round, botsAfterMs: 10000, random: rng).tables.single.map((x) => x.name), ['eager'],
          reason: 'bots at once, when asked for');
    });
  });

  group('over the relay', () {
    late Relay relay;
    setUp(() async {
      relay = Relay();
      await relay.serve();
    });
    tearDown(() => relay.close());

    // A waiter, and the table it is seated at, listened for as the room
    // is made: `seated` keeps nothing for a late listener, and a room
    // can be seated while the test is still joining the next. One never
    // seated ends with an error nobody need wait for.
    Future<(RelayTransport, WaitingRoom, Future<TableSpec>)> join(String name,
        {int rating = 1500,
        int target = gameOverScore,
        TableTiming timing = TableTiming.standard,
        SchnorrSigner? signer,
        int botsAfterMs = 3000,
        void Function(String)? log}) async {
      final s = signer ?? SchnorrSigner.generate();
      final t = RelayTransport(relays: [relay.url], signer: s, table: poolTag('unrated', target: target));
      await t.ready;
      final room = WaitingRoom(
          relay: t,
          pool: 'unrated',
          target: target,
          timing: timing,
          name: name,
          rating: rating,
          roundMs: 2000,
          botsAfterMs: botsAfterMs,
          heartbeatMs: 500,
          staleMs: 2000,
          log: log);
      final seated = room.seated.first..ignore();
      return (t, room, seated);
    }

    test('two waiting for a person are left waiting, whoever hosts, until one of them takes bots', () async {
      final a = await join('A');
      final b = await join('B');
      a.$2.waitForPerson();
      b.$2.waitForPerson();
      // Past the pool's wait for bots (three seconds here), and nobody is
      // seated: whoever hosts has heard the other wants a person.
      final early = Future.any([a.$3, b.$3]);
      expect(await early.then((_) => true).timeout(const Duration(seconds: 7), onTimeout: () => false), isFalse);
      b.$2.playWithBots();
      final specs = await Future.wait([a.$3, b.$3].map((f) => f.timeout(const Duration(seconds: 15))));
      expect(specs.map((s) => s.id).toSet().length, 1, reason: 'one table, the two of them and two bots');
      expect(specs.first.seats.whereType<HumanSeat>().length, 2);
      for (final r in [a, b]) {
        r.$2.close();
        r.$1.close();
      }
    });

    test('whoever hosts, a waiter who said nothing waits the pool\'s time', () async {
      // The host takes bots at once; the other said nothing, so waits the
      // pool's eight seconds here, not the host's none. The other has
      // waited a round longer (planned first) and is far from the host's
      // rating (neither takes the other along): held to the host's choice,
      // the other would be seated alone with bots at the host's first round.
      //
      // Far for as long as this test runs: a window widens 100 points a
      // round of two seconds, so 3000 apart is a minute's wait. At 500,
      // the other's window reached the host as its wait ran out, and a
      // host slow to choose seated them together.
      final signers = [SchnorrSigner.generate(), SchnorrSigner.generate()]..sort((a, b) => a.publicKey.compareTo(b.publicKey));
      const pool = 8000;
      final other = await join('Other', signer: signers[1], rating: 4500, botsAfterMs: pool);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final host = await join('Host', signer: signers[0], botsAfterMs: pool);
      while (host.$2.present.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final otherSeated = other.$3.then((spec) => (spec, DateTime.now().millisecondsSinceEpoch));
      host.$2.playWithBots();
      final hosted = await host.$3.timeout(const Duration(seconds: 10));
      expect(hosted.seats.whereType<HumanSeat>().single.key, signers[0].publicKey, reason: 'the host alone, with bots');
      final (seated, at) = await otherSeated.timeout(const Duration(seconds: 20));
      expect(at - other.$2.since, greaterThanOrEqualTo(pool), reason: 'not before the pool\'s wait');
      expect(seated.seats.whereType<HumanSeat>().single.key, signers[1].publicKey);
      for (final r in [host, other]) {
        r.$2.close();
        r.$1.close();
      }
    });

    test('three waiting: one host seats them at one table with a bot, and two hosts each at a table that names them',
        () async {
      // Normally the lowest key alone seats the round. On a machine busy
      // enough that its seating reaches the next in line after that one's
      // turn to host has come, both seat it, and each device takes the
      // lowest table id it has heard in time (matching.dart): together,
      // or apart. A device stops hosting once it is seated, so once all
      // three are, the hostings counted here are all there were.
      var hostings = 0;
      final rooms = [
        for (final n in ['A', 'B', 'C'])
          await join(n, log: (line) {
            if (line.contains(': hosting,')) hostings++;
          }),
      ];
      final specs = await Future.wait(rooms.map((r) => r.$3.timeout(const Duration(seconds: 15))));
      expect(hostings, greaterThan(0), reason: 'somebody hosted the round');
      for (var i = 0; i < rooms.length; i++) {
        expect(specs[i].seats.whereType<HumanSeat>().map((h) => h.key), contains(rooms[i].$2.me),
            reason: 'each sits at a table that names it');
        expect(specs[i].rated, isFalse);
      }
      if (hostings == 1) {
        expect(specs.map((s) => s.id).toSet().length, 1, reason: 'one seating, so one table');
        expect(specs.first.seats.whereType<HumanSeat>().length, 3);
        expect(specs.first.seats.whereType<BotSeat>().length, 1);
      } else {
        printOnFailure('$hostings hostings: the round was seated more than once');
      }
      for (final r in rooms) {
        r.$2.close();
        r.$1.close();
      }
    });

    // A seating as a host says it (matching.dart, _hostRound): these
    // keys, and bots in the other seats.
    Map<String, Object?> seating(String id, List<PublicKey> keys) => {
          'kind': 'match',
          'round': DateTime.now().millisecondsSinceEpoch ~/ 2000,
          'table': id,
          'seed': 1,
          'rated': false,
          'sealed': false,
          'target': gameOverScore,
          'timing': TableTiming.standard.toJson(),
          'seats': [
            for (final k in keys) {'key': k, 'name': 'W'},
            for (var s = keys.length; s < seatCount; s++) {'bot': Persona.roster[s].id},
          ],
          'policy': botPolicyVersion,
        };

    // The test as a host of its own, its seatings stored on the relay
    // before it returns: a device that joins after is handed them with
    // the relay's stored history, all at once.
    Future<RelayTransport> host() async {
      final t = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: poolTag('unrated'));
      await t.ready;
      return t;
    }

    Future<void> publish(RelayTransport host, List<Map<String, Object?>> seatings) async {
      final ids = {for (final s in seatings) s['table']};
      final echoed = host.lobby.where((e) => ids.contains((jsonDecode(e.content) as Map)['table'])).take(ids.length).toList();
      for (final s in seatings) {
        host.announce(s);
      }
      await echoed.timeout(const Duration(seconds: 15));
    }

    // Waiters nobody else seats: nobody is due bots for a minute, so no
    // room hosts a table of its own.
    Future<List<(RelayTransport, WaitingRoom, Future<TableSpec>)>> waiters(List<SchnorrSigner> signers) async =>
        [for (final s in signers) await join('W', signer: s, botsAfterMs: 60000)];

    test('a device takes the lowest table id among the seatings it has in time, whichever came first', () async {
      final signers = [for (var i = 0; i < 3; i++) SchnorrSigner.generate()];
      final keys = [for (final s in signers) s.publicKey];
      final ids = [newTableId(), newTableId()]..sort();
      final h = await host();
      await publish(h, [seating(ids[1], keys), seating(ids[0], keys)]);
      final rooms = await waiters(signers);
      final specs = await Future.wait(rooms.map((r) => r.$3.timeout(const Duration(seconds: 15))));
      expect(specs.map((s) => s.id), everyElement(ids[0]), reason: 'the lower id, though it came second');
      for (final r in rooms) {
        r.$2.close();
        r.$1.close();
      }
      h.close();
    });

    test('a seating that comes after a device has taken one does not move it', () async {
      // What parts people seated together, when a second host's seating
      // reaches some of them in time and the rest too late.
      final signers = [for (var i = 0; i < 3; i++) SchnorrSigner.generate()];
      final keys = [for (final s in signers) s.publicKey];
      final ids = [newTableId(), newTableId()]..sort();
      final h = await host();
      await publish(h, [seating(ids[1], keys)]);
      final rooms = await waiters(signers);
      final specs = await Future.wait(rooms.map((r) => r.$3.timeout(const Duration(seconds: 15))));
      expect(specs.map((s) => s.id), everyElement(ids[1]));
      final heard = [
        for (final r in rooms) r.$1.lobby.firstWhere((e) => (jsonDecode(e.content) as Map)['table'] == ids[0]),
      ];
      await publish(h, [seating(ids[0], keys)]);
      await Future.wait(heard).timeout(const Duration(seconds: 15));
      // A device that took it would within a tenth of a round of hearing
      // it (matching.dart); three tenths on, none has. One that drops it
      // as it arrives, as each must, cannot fail this however slow the
      // machine: the wait only gives a wrong one time to show itself.
      await Future<void>.delayed(Duration(milliseconds: rooms.first.$2.roundMs * 3 ~/ 10));
      for (final r in rooms) {
        expect(r.$2.spec!.id, ids[1], reason: 'every device heard the lower id, and none moved to it');
      }
      for (final r in rooms) {
        r.$2.close();
        r.$1.close();
      }
      h.close();
    });

    test('the host\'s clocks are the table\'s: the seating carries them to every seat', () async {
      // Three devices whose remote configs say three different clocks.
      // Whoever hosts the round seats the table, and every seat plays
      // by the host's — none by its own.
      //
      // Normally that is the lowest key, alone. On a machine busy enough
      // that the host's seating reaches the next in line after that one's
      // turn to host has come, both seat the round (matching.dart): each
      // table plays by the clocks of the device that seated it, and still
      // of no other.
      final timings = [
        for (final grace in [3000, 4000, 5000]) TableTiming.parse({'graceMs': grace}),
      ];
      final hosted = <int>{};
      final rooms = [
        for (var i = 0; i < 3; i++)
          await join('T$i', timing: timings[i], log: (line) {
            if (line.contains(': hosting,')) hosted.add(i);
          }),
      ];
      final specs = await Future.wait(rooms.map((r) => r.$3.timeout(const Duration(seconds: 15))));
      expect(hosted, isNotEmpty, reason: 'somebody hosted the round');
      for (final spec in specs) {
        expect(spec.timing, anyOf([for (final h in hosted) timings[h]]),
            reason: 'the clocks of the seating\'s host, of ${hosted.toList()..sort()}');
      }
      for (final r in rooms) {
        r.$2.close();
        r.$1.close();
      }
    });

    test('a game to another score waits in a pool of its own, and the table it gets says so', () async {
      final rooms = [await join('Short'), await join('Long', target: longGameScore)];
      final specs = await Future.wait(rooms.map((r) => r.$3.timeout(const Duration(seconds: 15))));
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

    test('a seating from a round long past does not seat somebody who has come back', () async {
      // The seating goes out on the stored kind, so that a device
      // arriving at a room code is handed the room announced before
      // it got there (nostr.dart, TableKinds.lobby). A pool is
      // subscribed to the same way and with no window on it, so a
      // relay hands a device that comes back to the pool every
      // seating it has ever carried there — this device's own
      // included.
      final mine = SchnorrSigner.generate();
      final first = [await join('A', signer: mine), await join('B'), await join('C')];
      final was = await first.first.$3.timeout(const Duration(seconds: 15));
      expect(was.seats.whereType<HumanSeat>().length, 3, reason: 'three were seated together');
      // That table is played and left; the others close their apps.
      for (final r in first) {
        r.$2.close();
        r.$1.close();
      }
      // Rounds go by — four of them at this room's two-second round,
      // where the real gap is a game's worth — and this device asks
      // for a game again.
      await Future<void>.delayed(const Duration(seconds: 8));
      final again = await join('A', signer: mine);
      final now = await again.$3.timeout(const Duration(seconds: 15));
      expect(now.id, isNot(was.id), reason: 'a new table, not the one it left');
      expect(now.seats.whereType<HumanSeat>().map((h) => h.key), [again.$2.me],
          reason: 'alone at the pool, so alone at the table: B and C are gone, and a seat that never moves is worse '
              'than a bot in it');
      again.$2.close();
      again.$1.close();
    });

    test('a device entering a pool is handed this round\'s seatings, not the pool\'s whole history', () async {
      // Every seating is stored, so that a room code's joiner finds the
      // room announced before it arrived; a pool's pile up with it, and
      // a device pressing Play must not be handed every one the pool has
      // ever carried. An hour of a busy pool's rounds, and one from now.
      // A socket a tag: on the deployed relay each tag is its own object.
      final sockets = <String, WebSocketChannel>{};
      final host = SchnorrSigner.generate();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      void store(String tag, int at, String what) =>
          sockets.putIfAbsent(tag, () => WebSocketChannel.connect(relaysForTag([relay.url], tag).single)).sink.add(jsonEncode([
            'EVENT',
            NostrEvent.sign(host, kind: TableKinds.lobby, content: jsonEncode({'what': what}), tags: [
              ['t', tag],
            ], createdAt: at)
                .toJson(),
          ]));
      final pool = poolTag('unrated');
      for (var i = 0; i < 40; i++) {
        store(pool, now - 3600 + i * 90, 'an old seating');
      }
      store(pool, now, 'this round\'s seating');
      // And a room announced an hour ago, whose joiner still has to
      // find it.
      store('ROOM42', now - 3600, 'a room');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final entering = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: pool);
      await entering.ready;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect([for (final e in entering.lobbySoFar) (jsonDecode(e.content) as Map)['what']], ['this round\'s seating'],
          reason: 'the pool as it is now, not as it has ever been');

      final joining = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: 'ROOM42');
      await joining.ready;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(joining.lobbySoFar, hasLength(1), reason: 'a room code still hands a late joiner the room');

      entering.close();
      joining.close();
      for (final ws in sockets.values) {
        await ws.sink.close();
      }
    });

    test('if the lowest key falls silent, the next seats the round', () async {
      final rooms = [for (final n in ['A', 'B']) await join(n)];
      rooms.sort((a, b) => a.$2.me.compareTo(b.$2.me));
      // The would-be host leaves without a word.
      rooms.first.$2.close();
      rooms.first.$1.close();
      final spec = await rooms.last.$3.timeout(const Duration(seconds: 15));
      expect(spec.seats.whereType<HumanSeat>().map((h) => h.key), [rooms.last.$2.me]);
      expect(spec.seats.whereType<BotSeat>().length, 3);
      rooms.last.$2.close();
      rooms.last.$1.close();
    });
  });
}
