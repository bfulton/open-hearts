/// A table where one seat writes to a relay the other cannot read: a
/// on two relays, writing its events to the first in its order; b on
/// the other relay only. Nothing a says reaches b the usual way, so
/// every action of a's goes unwitnessed — and, unsettled, is said
/// again by every path, where b does read it. The hand plays out.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
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
  tearDown(() {
    r1.close();
    r2.close();
  });

  test('a seat whose relay the other cannot read is still heard: what goes unanswered is said everywhere', () async {
    final signers = [FakeSigner('a'), FakeSigner('b')];
    final spec = TableSpec(id: 'half-deaf-table', seed: 11, seats: [
      HumanSeat(signers[0].publicKey),
      HumanSeat(signers[1].publicKey),
      BotSeat(Persona.roster[3]),
      BotSeat(Persona.roster[4]),
    ]);
    final ta = RelayTransport(relays: [r1.url, r2.url], signer: signers[0], table: spec.id);
    await ta.allReady.timeout(const Duration(seconds: 5));
    // b reads only the relay a does not write its table events to.
    final other = ta.relays.first == r1.url ? r2.url : r1.url;
    final tb = RelayTransport(relays: [other], signer: signers[1], table: spec.id);
    await tb.allReady.timeout(const Duration(seconds: 5));
    final clients = [
      TableClient(spec: spec, signer: signers[0], transport: ta, clock: WallClock()),
      TableClient(spec: spec, signer: signers[1], transport: tb, clock: WallClock()),
    ];
    final players = [for (final c in clients) Player(c, thinkMs: 100)];
    for (final c in clients) {
      c.start();
    }
    // The game plays out on both sides, nobody removed, at a pace
    // that says every event was heard the first time it was said.
    final done = Completer<void>();
    for (final c in clients) {
      c.changes.listen((_) {
        if (!done.isCompleted && clients.every((c) => c.done)) done.complete();
      });
    }
    await done.future.timeout(const Duration(minutes: 4), onTimeout: () {
      fail('the game did not finish:\n${clients.map((c) => c.describe()).join('\n')}');
    });
    for (final c in clients) {
      expect(c.holders.whereType<HumanSeat>().length, 2, reason: 'nobody was removed');
      final v = verifyRecord(spec, c.record, juries: c.juries, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    for (final p in players) {
      p.stop();
    }
    for (final c in clients) {
      c.close();
    }
    ta.close();
    tb.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
