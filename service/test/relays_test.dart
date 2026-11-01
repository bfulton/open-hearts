/// Several relays under one client: listening on all and writing to all,
/// a relay that refuses kept out for a while — over real sockets to two
/// local relays, either of which can be told to refuse.
library;

import 'dart:async';
import 'dart:convert';

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => installNativeSchnorr());
  late Relay r1;
  late Relay r2;
  setUp(() async {
    r1 = Relay();
    r2 = Relay();
    await r1.serve();
    await r2.serve();
  });
  tearDown(() async {
    await r1.close();
    await r2.close();
  });

  /// The next table message [t] hears, within a few seconds.
  Future<Map<String, Object?>> next(RelayTransport t) =>
      t.watch.first.then((m) => m.content).timeout(const Duration(seconds: 5));

  test('peers writing to different relays hear each other, listening on both', () async {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    // Opposite orders: whichever way the table id turns them, the two
    // list different relays first.
    final ta = RelayTransport(relays: [r1.url, r2.url], signer: a, table: 'both');
    final tb = RelayTransport(relays: [r2.url, r1.url], signer: b, table: 'both');
    await Future.wait([ta.allReady, tb.allReady]).timeout(const Duration(seconds: 5));
    expect(ta.relays.first, isNot(tb.relays.first));

    final heardByB = next(tb);
    ta.sayWatch({'n': 1});
    expect(await heardByB, {'n': 1});
    final heardByA = next(ta);
    tb.sayWatch({'n': 2});
    expect(await heardByA, {'n': 2});
    expect(ta.refusal, isNull);
    expect(tb.refusal, isNull);
    ta.close();
    tb.close();
  });

  test('a lobby announcement and a signal reach a peer that reads only one of the relays', () async {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    // b can read only one of the relays a writes to: a writes
    // everything to both, so b hears it anyway.
    final ta = RelayTransport(relays: [r1.url, r2.url], signer: a, table: 'half-deaf');
    await ta.allReady.timeout(const Duration(seconds: 5));
    // b reads only the relay a lists second.
    final other = ta.relays.first == r1.url ? r2.url : r1.url;
    final tb = RelayTransport(relays: [other], signer: b, table: 'half-deaf');
    await tb.allReady.timeout(const Duration(seconds: 5));

    final beat = tb.lobby.first.timeout(const Duration(seconds: 5));
    ta.announce({'kind': 'here', 'name': 'Ada'}, ephemeral: true);
    expect(jsonDecode((await beat).content), {'kind': 'here', 'name': 'Ada'});

    final signal = tb.signals.first.timeout(const Duration(seconds: 5));
    ta.signal(b.publicKey, Signal(from: a.publicKey, type: 'offer', payload: const {'sdp': 'x'}));
    expect((await signal).type, 'offer');
    ta.close();
    tb.close();
  });

  test('a relay that refuses is left out for a while, and the event still arrives', () async {
    r1.refuse = (_) => 'pow: 28 bits needed';
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final relays = [r1.url, r2.url];
    final ta = RelayTransport(relays: relays, signer: a, table: 'one-refusing');
    final tb = RelayTransport(relays: relays, signer: b, table: 'one-refusing');
    await Future.wait([ta.allReady, tb.allReady]).timeout(const Duration(seconds: 5));

    // r1 refuses and r2 takes: the message gets through, and with one
    // relay taking it, nothing is reported.
    final heard = next(tb);
    ta.sayWatch({'n': 1});
    expect(await heard, {'n': 1});
    expect(ta.refusal, isNull);

    // Once r1's refusal has landed it is out of the running for a
    // while, and later events are not offered to it at all.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    var refusalsAtR1 = 0;
    r1.refuse = (_) {
      refusalsAtR1++;
      return 'pow: 28 bits needed';
    };
    final heard2 = next(tb);
    ta.sayWatch({'n': 2});
    expect(await heard2, {'n': 2});
    expect(refusalsAtR1, 0);
    ta.close();
    tb.close();
  });

  test('every relay refusing is said, and unsaid once one takes events again', () async {
    r1.refuse = (_) => 'pow: 28 bits needed';
    r2.refuse = (_) => 'rate-limited: slow down';
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final relays = [r1.url, r2.url];
    // A refusal lasts a second here, a minute in the app.
    final ta = RelayTransport(relays: relays, signer: a, table: 'all-refusing', refusalMs: 1000);
    final tb = RelayTransport(relays: relays, signer: b, table: 'all-refusing');
    await Future.wait([ta.allReady, tb.allReady]).timeout(const Duration(seconds: 5));

    final said = ta.refusals.first.timeout(const Duration(seconds: 5));
    ta.sayWatch({'n': 1});
    final reason = await said;
    expect(reason, isNotNull);
    expect(reason, anyOf(startsWith('pow:'), startsWith('rate-limited:')));
    expect(ta.refusal, reason);

    // Both relays are out of the running now: the next event goes
    // nowhere, quietly.
    var heardAny = false;
    final sub = tb.watch.listen((_) => heardAny = true);
    ta.sayWatch({'n': 2});
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(heardAny, isFalse);
    await sub.cancel();

    // A relay relents, the refusals run out, and the next event finds
    // it: taken, heard, and the refusal unsaid.
    r2.refuse = null;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final unsaid = ta.refusals.where((r) => r == null).first.timeout(const Duration(seconds: 5));
    final heard = next(tb);
    ta.sayWatch({'n': 3});
    expect(await heard, {'n': 3});
    await unsaid;
    expect(ta.refusal, isNull);
    ta.close();
    tb.close();
  });

  test('what must not go nowhere quietly is waited on: taken, refused everywhere, or nowhere to go', () async {
    final a = SchnorrSigner.generate();
    final relays = [r1.url, r2.url];
    final ta = RelayTransport(relays: relays, signer: a, table: 'taken', refusalMs: 5000);
    await ta.allReady.timeout(const Duration(seconds: 5));

    // One relay refusing and one taking: taken — and stored, so a
    // reader who comes later finds it.
    r1.refuse = (_) => 'rate-limited: slow down';
    expect(await ta.announceTaken({'n': 1}), isTrue);
    final later = RelayTransport(relays: [r2.url], signer: SchnorrSigner.generate(), table: 'taken');
    await later.allReady.timeout(const Duration(seconds: 5));
    expect([for (final e in later.lobbySoFar) jsonDecode(e.content)], contains(equals({'n': 1})));
    later.close();

    // Every relay refusing: not taken, and said as soon as the last
    // refusal is in rather than when the wait runs out.
    r2.refuse = (_) => 'rate-limited: slow down';
    final clock = Stopwatch()..start();
    expect(await ta.announceTaken({'n': 2}, within: const Duration(seconds: 8)), isFalse);
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    ta.close();

    // Every relay gone: nowhere to go, and said at once.
    r1.refuse = null;
    r2.refuse = null;
    final tb = RelayTransport(relays: relays, signer: a, table: 'taken');
    await tb.allReady.timeout(const Duration(seconds: 5));
    await r1.close();
    await r2.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    clock.reset();
    expect(await tb.announceTaken({'n': 3}, within: const Duration(seconds: 8)), isFalse);
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));

    // And closing with an answer still owed gives it: not taken.
    final owed = tb.announceTaken({'n': 4}, within: const Duration(seconds: 30));
    tb.close();
    expect(await owed.timeout(const Duration(seconds: 2)), isFalse);
  });

  test('presence over two relays: everyone sees everyone', () async {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final pa = RelayPresence(relays: [r1.url, r2.url], signer: a, everyMs: 300);
    final pb = RelayPresence(relays: [r2.url, r1.url], signer: b, everyMs: 300);
    await Future.wait([pa.ready, pb.ready]).timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(pa.online(withinMs: 3000), containsAll([a.publicKey, b.publicKey]));
    expect(pb.online(withinMs: 3000), containsAll([a.publicKey, b.publicKey]));
    pa.close();
    pb.close();
  });
}
