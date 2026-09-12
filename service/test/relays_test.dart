/// Several relays under one client: listening on all, writing to one,
/// moving on when a relay refuses — over real sockets to two local
/// relays, one of which can be told to refuse.
library;

import 'dart:async';

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
      t.incoming.first.then((m) => m.message).timeout(const Duration(seconds: 5));

  test('peers writing to different relays hear each other, listening on both', () async {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    // Opposite orders: whichever way the table id turns them, the two
    // write to different relays first.
    final ta = RelayTransport(relays: [r1.url, r2.url], signer: a, table: 'both');
    final tb = RelayTransport(relays: [r2.url, r1.url], signer: b, table: 'both');
    await Future.wait([ta.allReady, tb.allReady]).timeout(const Duration(seconds: 5));
    expect(ta.relays.first, isNot(tb.relays.first));

    final heardByB = next(tb);
    ta.broadcast({'n': 1});
    expect(await heardByB, {'n': 1});
    final heardByA = next(ta);
    tb.broadcast({'n': 2});
    expect(await heardByA, {'n': 2});
    expect(ta.refusal, isNull);
    expect(tb.refusal, isNull);
    ta.close();
    tb.close();
  });

  test('a relay that refuses is moved past, and the event still arrives', () async {
    r1.refuse = (_) => 'pow: 28 bits needed';
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final relays = [r1.url, r2.url];
    final ta = RelayTransport(relays: relays, signer: a, table: 'one-refusing');
    final tb = RelayTransport(relays: relays, signer: b, table: 'one-refusing');
    await Future.wait([ta.allReady, tb.allReady]).timeout(const Duration(seconds: 5));

    // Whichever relay comes first for this table, r1 refuses and r2
    // takes; the message gets through either way, and with one relay
    // taking it, nothing is reported.
    final heard = next(tb);
    ta.broadcast({'n': 1});
    expect(await heard, {'n': 1});
    expect(ta.refusal, isNull);

    // A second event goes straight to the relay that took the first:
    // r1 refused once and is out of the running for a while.
    var refusalsAtR1 = 0;
    r1.refuse = (_) {
      refusalsAtR1++;
      return 'pow: 28 bits needed';
    };
    final heard2 = next(tb);
    ta.broadcast({'n': 2});
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
    ta.broadcast({'n': 1});
    final reason = await said;
    expect(reason, isNotNull);
    expect(reason, anyOf(startsWith('pow:'), startsWith('rate-limited:')));
    expect(ta.refusal, reason);

    // Both relays are out of the running now: the next event goes
    // nowhere, quietly.
    var heardAny = false;
    final sub = tb.incoming.listen((_) => heardAny = true);
    ta.broadcast({'n': 2});
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(heardAny, isFalse);
    await sub.cancel();

    // A relay relents, the refusals run out, and the next event finds
    // it: taken, heard, and the refusal unsaid.
    r2.refuse = null;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final unsaid = ta.refusals.where((r) => r == null).first.timeout(const Duration(seconds: 5));
    final heard = next(tb);
    ta.broadcast({'n': 3});
    expect(await heard, {'n': 3});
    await unsaid;
    expect(ta.refusal, isNull);
    ta.close();
    tb.close();
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
