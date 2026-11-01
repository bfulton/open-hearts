/// Strangers seated on the relay, by the house (packages/table, matching.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
    final house = SchnorrSigner.generate();
    final houseSecret = Uint8List.fromList(List.generate(32, (i) => i));
    setUp(() async {
      relay = Relay(house: house.publicKey);
      await relay.serve();
    });
    tearDown(() => relay.close());

    // The house seating [pool]'s tag, on a socket of its own as the house
    // binary has one (service/bin/house.dart), at a round of two seconds.
    // Its bots are the roster's at their starting ratings.
    Future<(RelayTransport, PoolHost)> seats(
        {String pool = 'unrated',
        int target = gameOverScore,
        TableTiming timing = TableTiming.standard,
        int staleMs = 2000,
        int botsAfterMs = 3000,
        int idleMs = 60000,
        void Function()? onIdle,
        Relay? on,
        SchnorrSigner? as}) async {
      final t = RelayTransport(relays: [(on ?? relay).url], signer: as ?? house, table: poolTag(pool, target: target));
      await t.ready;
      final host = PoolHost(
          relay: t,
          pool: pool,
          secret: houseSecret,
          target: target,
          bots: botsNear(Ledger(prior: botPrior)),
          timing: timing,
          roundMs: 2000,
          staleMs: staleMs,
          botsAfterMs: botsAfterMs,
          idleMs: idleMs,
          onIdle: onIdle);
      return (t, host);
    }

    // A waiter, and the table it is seated at, listened for as the room
    // is made: `seated` keeps nothing for a late listener, and a room
    // can be seated while the test is still joining the next. One never
    // seated ends with an error nobody need wait for.
    Future<(RelayTransport, WaitingRoom, Future<TableSpec>)> join(String name,
        {int rating = 1500,
        int target = gameOverScore,
        SchnorrSigner? signer,
        int botsAfterMs = 3000,
        int? clockOutMs,
        Relay? on,
        PublicKey? houseKey}) async {
      final s = signer ?? SchnorrSigner.generate();
      final t = RelayTransport(relays: [(on ?? relay).url], signer: s, table: poolTag('unrated', target: target));
      await t.ready;
      final room = WaitingRoom(
          relay: t,
          pool: 'unrated',
          target: target,
          house: houseKey ?? house.publicKey,
          name: name,
          rating: rating,
          roundMs: 2000,
          botsAfterMs: botsAfterMs,
          heartbeatMs: 500,
          staleMs: 2000,
          nowMs: clockOutMs == null ? null : DateTime.now().millisecondsSinceEpoch + clockOutMs);
      final seated = room.seated.first..ignore();
      return (t, room, seated);
    }

    void closeAll(Iterable<(RelayTransport, Object, Object?)> them) {
      for (final (t, x, _) in them) {
        if (x is WaitingRoom) x.close();
        if (x is PoolHost) x.close();
        t.close();
      }
    }

    test('two waiting for a person are left waiting until one of them takes bots', () async {
      final h = await seats();
      final a = await join('A');
      final b = await join('B');
      a.$2.waitForPerson();
      b.$2.waitForPerson();
      // Past the pool's wait for bots (three seconds here), and nobody is
      // seated: the house has heard both want a person.
      final early = Future.any([a.$3, b.$3]);
      expect(await early.then((_) => true).timeout(const Duration(seconds: 7), onTimeout: () => false), isFalse);
      b.$2.playWithBots();
      final specs = await Future.wait([a.$3, b.$3].map((f) => f.timeout(const Duration(seconds: 15))));
      expect(specs.map((s) => s.id).toSet().length, 1, reason: 'one table, the two of them and two bots');
      expect(specs.first.seats.whereType<HumanSeat>().length, 2);
      expect(specs.first.salt, seatingSalt(houseSecret, specs.first), reason: 'salted with the house\'s secret, as a table it seated');
      closeAll([a, b, (h.$1, h.$2, null)]);
    });

    test('a name is seated as it may be shown: nothing in it that turns text round, and no longer than a profile keeps one', () async {
      final h = await seats();
      final a = await join('\u202ekcuf\u202c${'x' * 500}');
      a.$2.playWithBots();
      await a.$3.timeout(const Duration(seconds: 10));
      expect(a.$2.seatNames.values, ['kcuf${'x' * (longestName - 4)}']);
      closeAll([a, (h.$1, h.$2, null)]);
    });

    test('a waiter who said nothing waits the pool\'s time, whatever another chose', () async {
      // One takes bots at once; the other said nothing, so waits the
      // pool's eight seconds here. Far apart in rating for as long as
      // this test runs (a window widens 100 points a round of two
      // seconds, so 3000 apart is a minute's wait), so neither takes the
      // other along.
      const pool = 8000;
      final h = await seats(botsAfterMs: pool);
      final other = await join('Other', rating: 4500, botsAfterMs: pool);
      final eager = await join('Eager', botsAfterMs: pool);
      final otherSeated = other.$3.then((spec) => (spec, DateTime.now().millisecondsSinceEpoch));
      eager.$2.playWithBots();
      final hosted = await eager.$3.timeout(const Duration(seconds: 10));
      expect(hosted.seats.whereType<HumanSeat>().single.key, eager.$2.me, reason: 'alone, with bots, at once');
      final (seated, at) = await otherSeated.timeout(const Duration(seconds: 20));
      expect(at - other.$2.since, greaterThanOrEqualTo(pool), reason: 'not before the pool\'s wait');
      expect(seated.seats.whereType<HumanSeat>().single.key, other.$2.me);
      closeAll([eager, other, (h.$1, h.$2, null)]);
    });

    test('five waiting: four at a table, and the fifth seated with none of them, however long they stay heard', () async {
      // Nobody is due bots for a minute, so a table is four people; and
      // somebody seated is heard of, by their last heartbeat, for twenty
      // seconds. The fifth is left over, and the pool's next rounds have
      // only the fifth in them: the four left it as they were seated,
      // not as they went quiet.
      final h = await seats(staleMs: 20000, botsAfterMs: 60000);
      final watching = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: poolTag('unrated'));
      await watching.ready;
      final seatings = <List<String>>[];
      final heard = watching.lobby.listen((e) {
        final c = jsonDecode(e.content) as Map;
        if (c['kind'] == 'match') seatings.add([for (final s in c['seats'] as List) if ((s as Map)['key'] is String) s['key'] as String]);
      });
      final rooms = [for (var i = 0; i < 5; i++) await join('P$i', botsAfterMs: 60000)];
      // The four, whoever they are.
      while (seatings.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final four = seatings.single;
      expect(four, hasLength(4));
      final fifth = rooms.singleWhere((r) => !four.contains(r.$2.me));
      // And the fifth's own screen counts nobody but itself, the four
      // gone from the pool with the seating, not a heartbeat later.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fifth.$2.present.map((w) => w.key), [fifth.$2.me]);
      // Three rounds on, the fifth is still waiting, and nobody else was
      // seated.
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(seatings, hasLength(1), reason: 'the four were seated once, and the fifth not with any of them');
      expect(fifth.$2.spec, isNull);
      // Then the fifth asks for bots, and sits with them alone.
      fifth.$2.playWithBots();
      final spec = await fifth.$3.timeout(const Duration(seconds: 10));
      expect(spec.seats.whereType<HumanSeat>().map((s) => s.key), [fifth.$2.me]);
      expect(seatings, hasLength(2));
      await heard.cancel();
      watching.close();
      closeAll([...rooms, (h.$1, h.$2, null)]);
    });

    test('somebody seated is not heard for a while, and then is: a device that never took its seating waits on', () async {
      // A device that goes on saying it is waiting after its seating, as
      // one that could not sit at the table would: a seating, then none
      // while what it says may be from before it was seated, and then
      // another.
      final h = await seats(staleMs: 5000, botsAfterMs: 0);
      final watching = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: poolTag('unrated'));
      await watching.ready;
      final stubborn = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: poolTag('unrated'));
      await stubborn.ready;
      final at = <int>[];
      final heard = watching.lobby.listen((e) {
        final c = jsonDecode(e.content) as Map;
        if (c['kind'] == 'match' && (c['seats'] as List).any((s) => (s as Map)['key'] == stubborn.signer.publicKey)) {
          at.add(DateTime.now().millisecondsSinceEpoch);
        }
      });
      final since = DateTime.now().millisecondsSinceEpoch;
      final beat = Timer.periodic(const Duration(milliseconds: 500), (_) {
        stubborn.announce({'kind': 'wait', 'name': 'S', 'rating': 1500, 'since': since}, ephemeral: true);
      });
      // And somebody else waiting, for a person (the pool's own wait
      // here being none) and far from it in rating, whose screen counts
      // who is waiting by the same rule, over its own two seconds.
      final other = await join('O', rating: 4500);
      other.$2.waitForPerson();
      bool counted() => other.$2.present.any((w) => w.key == stubborn.signer.publicKey);
      while (!counted()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      while (at.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(counted(), isFalse, reason: 'seated a second ago, so not waiting, whatever it still says');
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      expect(counted(), isTrue, reason: 'still saying it waits, after the seating could have reached it: waiting');
      while (at.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (DateTime.now().millisecondsSinceEpoch - since > 20000) fail('seated ${at.length} times in twenty seconds');
      }
      expect(at[1] - at[0], greaterThanOrEqualTo(5000), reason: 'not heard for the house\'s five seconds after its seating');
      beat.cancel();
      await heard.cancel();
      watching.close();
      stubborn.close();
      closeAll([other, (h.$1, h.$2, null)]);
    });

    // A seating as the house says it (matching.dart, PoolHost): these
    // keys, bots in the other seats, salted with [salt], naming [named]
    // as its house, and the table its spec names.
    Map<String, Object?> seating(String salt, List<PublicKey> keys, PublicKey named) {
      final spec = TableSpec(
        seed: 1,
        seats: [for (final k in keys) HumanSeat(k), for (var s = keys.length; s < seatCount; s++) BotSeat(Persona.roster[s])],
        sealed: true,
        house: named,
        salt: salt,
      );
      return {
        'kind': 'match',
        'round': DateTime.now().millisecondsSinceEpoch ~/ 2000,
        'table': spec.id,
        'salt': salt,
        'seed': 1,
        'rated': false,
        'sealed': true,
        'target': gameOverScore,
        'timing': TableTiming.standard.toJson(),
        'house': named,
        'seats': [
          for (final k in keys) {'key': k, 'name': 'W'},
          for (var s = keys.length; s < seatCount; s++) {'bot': Persona.roster[s].id},
        ],
        'policy': botPolicyVersion,
      };
    }

    test('a seating from anyone but the house: the relay carries none, and a device would take none', () async {
      // Waiters nobody seats: no house is in the pool.
      final rooms = [for (var i = 0; i < 3; i++) await join('W', botsAfterMs: 60000)];
      final keys = [for (final r in rooms) r.$2.me];
      final stranger = SchnorrSigner.generate();
      final t = RelayTransport(relays: [relay.url], signer: stranger, table: poolTag('unrated'));
      await t.ready;
      final watching = RelayTransport(relays: [relay.url], signer: SchnorrSigner.generate(), table: poolTag('unrated'));
      await watching.ready;
      final carried = <String>[];
      final listening = watching.lobby.listen((e) {
        if ((jsonDecode(e.content) as Map)['kind'] == 'match') carried.add(e.pubkey);
      });
      // One naming this relay's house, and one naming the stranger, as a
      // house of its own: each answered as taken, so that the device
      // that said it is not held out of the relay for it, and neither
      // carried to anybody.
      expect(await t.announceTaken(seating(newSalt(), keys, house.publicKey)), isTrue);
      expect(await t.announceTaken(seating(newSalt(), keys, stranger.publicKey)), isTrue);
      expect(t.refusal, isNull, reason: 'nothing this device says is refused');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(carried, isEmpty, reason: 'the relay carries a pool\'s seating from its house alone');
      await listening.cancel();
      watching.close();
      // And a device whose house is not the relay's takes nothing the
      // relay's house says: here a relay whose house is the stranger,
      // and a device that plays with another.
      final other = Relay(house: stranger.publicKey);
      await other.serve();
      final mine = await join('M', on: other, botsAfterMs: 60000);
      final t2 = RelayTransport(relays: [other.url], signer: stranger, table: poolTag('unrated'));
      await t2.ready;
      // One naming this device's house, as its house's would, but said
      // by the stranger, whom this relay carries.
      expect(await t2.announceTaken(seating(newSalt(), [mine.$2.me], house.publicKey)), isTrue, reason: 'the relay\'s own house');
      expect(await mine.$3.then((_) => true).timeout(const Duration(seconds: 3), onTimeout: () => false), isFalse,
          reason: 'not said by this device\'s house');
      for (final r in rooms) {
        expect(r.$2.spec, isNull);
      }
      t.close();
      t2.close();
      closeAll([...rooms, mine]);
      await other.close();
    });

    test('a seating that names no target is not sat at', () async {
      final waiting = await join('W', botsAfterMs: 60000);
      final t = RelayTransport(relays: [relay.url], signer: house, table: poolTag('unrated'));
      await t.ready;
      expect(await t.announceTaken(seating(newSalt(), [waiting.$2.me], house.publicKey)..remove('target')), isTrue);
      expect(await waiting.$3.then((_) => true).timeout(const Duration(seconds: 2), onTimeout: () => false), isFalse);
      expect(await t.announceTaken(seating(newSalt(), [waiting.$2.me], house.publicKey)), isTrue);
      expect((await waiting.$3.timeout(const Duration(seconds: 5))).target, gameOverScore, reason: 'one that names it is');
      t.close();
      closeAll([waiting]);
    });

    test('the operator\'s clocks are the table\'s: as the house was last told them, whatever a device\'s say', () async {
      final first = TableTiming.parse({'graceMs': 3000});
      final then = TableTiming.parse({'graceMs': 5000});
      final h = await seats(timing: first, botsAfterMs: 0);
      final a = await join('A', botsAfterMs: 0);
      expect((await a.$3.timeout(const Duration(seconds: 10))).timing, first);
      h.$2.timing = then;
      final b = await join('B', botsAfterMs: 0);
      expect((await b.$3.timeout(const Duration(seconds: 10))).timing, then, reason: 'the next seating\'s');
      closeAll([a, b, (h.$1, h.$2, null)]);
    });

    test('a game to another score waits in a pool of its own, and the table it gets says so', () async {
      final hosts = [await seats(), await seats(target: longGameScore)];
      final rooms = [await join('Short'), await join('Long', target: longGameScore)];
      final specs = await Future.wait(rooms.map((r) => r.$3.timeout(const Duration(seconds: 15))));
      expect(specs[0].target, gameOverScore);
      expect(specs[1].target, longGameScore);
      expect(specs[0].id, isNot(specs[1].id), reason: 'two games nobody can play at once are two tables');
      for (final spec in specs) {
        expect(spec.seats.whereType<HumanSeat>().length, 1, reason: 'each waited alone and got bots');
        expect(spec.house, house.publicKey);
        expect(spec.sealed, isTrue);
      }
      closeAll([...rooms, for (final h in hosts) (h.$1, h.$2, null)]);
    });

    test('a seating from a round long past does not seat somebody who has come back', () async {
      // The seating goes out on the stored kind, so that a device
      // arriving at a room code is handed the room announced before
      // it got there (nostr.dart, TableKinds.lobby). A pool is
      // subscribed to the same way, so a relay hands a device that
      // comes back to the pool the last minute's seatings — this
      // device's own included.
      final h = await seats();
      final mine = SchnorrSigner.generate();
      final first = [await join('A', signer: mine), await join('B'), await join('C')];
      final was = await first.first.$3.timeout(const Duration(seconds: 15));
      expect(was.seats.whereType<HumanSeat>().length, 3, reason: 'three were seated together');
      // That table is played and left; the others close their apps.
      closeAll(first);
      // Rounds go by — four of them at this pool's two-second round,
      // where the real gap is a game's worth — and this device asks
      // for a game again.
      await Future<void>.delayed(const Duration(seconds: 8));
      final again = await join('A', signer: mine);
      final now = await again.$3.timeout(const Duration(seconds: 15));
      expect(now.id, isNot(was.id), reason: 'a new table, not the one it left');
      expect(now.seats.whereType<HumanSeat>().map((h) => h.key), [again.$2.me],
          reason: 'alone at the pool, so alone at the table: B and C are gone, and a seat that never moves is worse '
              'than a bot in it');
      closeAll([again, (h.$1, h.$2, null)]);
    });

    test('a device entering a pool is handed this round\'s seatings, not the pool\'s whole history', () async {
      // Every seating is stored, so that a room code's joiner finds the
      // room announced before it arrived; a pool's pile up with it, and
      // a device pressing Play must not be handed every one the pool has
      // ever carried. An hour of a busy pool's rounds, and one from now.
      // A socket a tag: on the deployed relay each tag is its own object.
      final sockets = <String, WebSocketChannel>{};
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Each kept once the relay says so: what a device entering finds is
      // whatever the relay had taken by then.
      final unkept = <String>{};
      final allKept = Completer<void>();
      void store(String tag, int at, String what) {
        final socket = sockets.putIfAbsent(tag, () {
          final s = WebSocketChannel.connect(relaysForTag([relay.url], tag).single);
          s.stream.listen((m) {
            final said = jsonDecode(m as String) as List;
            if (said[0] == 'OK' && said[2] == true && unkept.remove(said[1]) && unkept.isEmpty) allKept.complete();
          });
          return s;
        });
        final e = NostrEvent.sign(house, kind: TableKinds.lobby, content: jsonEncode({'kind': 'match', 'what': what}), tags: [
          ['t', tag],
        ], createdAt: at);
        unkept.add(e.id);
        socket.sink.add(jsonEncode(['EVENT', e.toJson()]));
      }
      final pool = poolTag('unrated');
      for (var i = 0; i < 40; i++) {
        store(pool, now - 3600 + i * 90, 'an old seating');
      }
      store(pool, now, 'this round\'s seating');
      // And a room announced an hour ago, whose joiner still has to
      // find it.
      store('ROOM42', now - 3600, 'a room');
      await allKept.future.timeout(const Duration(seconds: 15), onTimeout: () => fail('${unkept.length} of 42 not kept'));

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

    test('a pool nobody has waited in for a while is left, and one somebody waits in is not', () async {
      final left = Completer<void>();
      final h = await seats(idleMs: 3000, onIdle: left.complete);
      final a = await join('A', botsAfterMs: 60000);
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(left.isCompleted, isFalse, reason: 'somebody is waiting');
      closeAll([a]);
      await left.future.timeout(const Duration(seconds: 8));
      closeAll([(h.$1, h.$2, null)]);
    });

    test('a device whose clock is out waits the pool\'s time all the same, by the house\'s clock', () async {
      // Two minutes ahead, and two behind, as the service lets a phone
      // be (service/functions/settings.mjs, requestToleranceS): ahead,
      // it would seem never to have waited, and leave unseated; behind,
      // to have waited two minutes, and get bots at once. Far apart in
      // rating, so neither takes the other along.
      final h = await seats();
      final joined = DateTime.now().millisecondsSinceEpoch;
      final ahead = await join('Ahead', clockOutMs: 120000);
      final behind = await join('Behind', rating: 4500, clockOutMs: -120000);
      for (final r in [ahead, behind]) {
        await r.$3.timeout(const Duration(seconds: 10));
        final waited = DateTime.now().millisecondsSinceEpoch - joined;
        expect(waited, greaterThanOrEqualTo(3000), reason: '${r.$2.name}: not before the pool\'s three seconds');
      }
      closeAll([ahead, behind, (h.$1, h.$2, null)]);
    });

    test('somebody who goes without a word is seated with nobody', () async {
      final h = await seats();
      final rooms = [for (final n in ['A', 'B']) await join(n, botsAfterMs: 60000)];
      // One leaves without a word; the other asks for bots once the
      // house has stopped hearing the first.
      closeAll([rooms.first]);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      rooms.last.$2.playWithBots();
      final spec = await rooms.last.$3.timeout(const Duration(seconds: 15));
      expect(spec.seats.whereType<HumanSeat>().map((h) => h.key), [rooms.last.$2.me]);
      expect(spec.seats.whereType<BotSeat>().length, 3);
      closeAll([rooms.last, (h.$1, h.$2, null)]);
    });
  });

  test('bots near a table\'s rating, by the ratings the results say, no persona twice', () {
    // Every bot at its starting rating but one, rated far above them all.
    final ledger = Ledger(prior: botPrior);
    final top = Persona.all.reduce((a, b) => Persona.priorRating(a.level) >= Persona.priorRating(b.level) ? a : b);
    final ranked = (ledger.of(top.id).mu + 1000).round();
    final pick = botsNear(ledger);
    expect(pick(ranked, 1, Random(1)).single.level, top.level, reason: 'the nearest level to a rating above every bot');
    final three = pick(1500, 3, Random(2));
    expect(three.map((p) => p.name).toSet(), hasLength(3), reason: 'no name twice');
    expect(botPrior(top.id)!.mu, Persona.priorRating(top.level));
    expect(botPrior('ab' * 16), isNull, reason: 'an account starts fresh');
  });
}
