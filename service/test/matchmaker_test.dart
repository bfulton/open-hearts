import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

Waiting w(String name, {int since = 0, bool priority = false}) =>
    Waiting(key: name.padRight(64, '0'), name: name, since: since)..priority = priority;

void main() {
  group('the rule', () {
    final rng = Random(1);

    test('four to a table, at random; the remainder waits on', () {
      final p = plan([for (var i = 0; i < 6; i++) w('p$i')], nowMs: 1000, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 1);
      expect(p.tables.first.length, 4);
      expect(p.leftOver.length, 2);
      expect({...p.tables.first, ...p.leftOver}.length, 6);
    });

    test('whoever was left over goes first next time', () {
      final left = [w('a', priority: true), w('b', priority: true)];
      final fresh = [for (var i = 0; i < 5; i++) w('f$i')];
      final p = plan([...fresh, ...left], nowMs: 1000, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 1);
      expect(p.tables.first.map((x) => x.name), containsAll(['a', 'b']));
      expect(p.leftOver.length, 3);
    });

    test('nobody waits past ten seconds: bots take the empty seats', () {
      expect(plan([w('solo', since: 0)], nowMs: 9000, botsAfterMs: 10000, random: rng).tables, isEmpty);
      final p = plan([w('solo', since: 0), w('newer', since: 8000)], nowMs: 10000, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 1);
      expect(p.tables.first.length, 2, reason: 'both go, with two bots');
      expect(p.leftOver, isEmpty);
    });

    test('a full table forms before anyone is kept for bots', () {
      final p = plan([for (var i = 0; i < 5; i++) w('p$i', since: 0)], nowMs: 20000, botsAfterMs: 10000, random: rng);
      expect(p.tables.length, 2);
      expect(p.tables.map((t) => t.length).toList(), [4, 1]);
    });
  });

  group('over the relay', () {
    late Relay relay;
    late Matchmaker mm;
    setUp(() async {
      relay = Relay();
      await relay.serve();
      mm = Matchmaker(relayUrl: relay.url, roundMs: 300, botsAfterMs: 700, staleMs: 2000, random: Random(2));
      await mm.start();
    });
    tearDown(() async {
      await mm.close();
      await relay.close();
    });

    Future<Map<String, Object?>> waitFor(RelayTransport t, PublicKey me) {
      final c = Completer<Map<String, Object?>>();
      t.lobby.listen((e) {
        if (e.kind != TableKinds.lobby || c.isCompleted) return;
        final m = Map<String, Object?>.from(jsonDecode(e.content) as Map);
        if (m['kind'] == 'match' && (m['seats'] as List).any((s) => (s as Map)['key'] == me)) c.complete(m);
      });
      return c.future.timeout(const Duration(seconds: 10));
    }

    test('two waiting in the unrated pool are seated together after a round, with bots', () async {
      final a = SchnorrSigner.generate();
      final b = SchnorrSigner.generate();
      final ta = RelayTransport(url: relay.url, signer: a, table: Matchmaker.poolTag('unrated'));
      final tb = RelayTransport(url: relay.url, signer: b, table: Matchmaker.poolTag('unrated'));
      await Future.wait([ta.ready, tb.ready]);
      final matchA = waitFor(ta, a.publicKey);
      final matchB = waitFor(tb, b.publicKey);
      final beat = Timer.periodic(const Duration(milliseconds: 200), (_) {
        ta.announce({'kind': 'wait', 'name': 'A'}, ephemeral: true);
        tb.announce({'kind': 'wait', 'name': 'B'}, ephemeral: true);
      });
      final ma = await matchA;
      final mb = await matchB;
      beat.cancel();
      expect(ma['table'], mb['table']);
      expect(ma['rated'], isFalse);
      final seats = ma['seats'] as List;
      expect(seats.where((s) => (s as Map).containsKey('key')).length, 2);
      expect(seats.where((s) => (s as Map).containsKey('bot')).length, 2);
      expect(mm.tablesMade, 1);
      // Their heartbeats still in flight do not seat them again.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(mm.tablesMade, 1);
      ta.close();
      tb.close();
    });

    test('the rated pool is its own, and says so', () async {
      final a = SchnorrSigner.generate();
      final ta = RelayTransport(url: relay.url, signer: a, table: Matchmaker.poolTag('rated'));
      await ta.ready;
      final match = waitFor(ta, a.publicKey);
      final beat = Timer.periodic(const Duration(milliseconds: 200), (_) => ta.announce({'kind': 'wait', 'name': 'A'}, ephemeral: true));
      final m = await match;
      beat.cancel();
      expect(m['rated'], isTrue);
      expect((m['seats'] as List).where((s) => (s as Map).containsKey('bot')).length, 3);
      ta.close();
    });
  });
}
