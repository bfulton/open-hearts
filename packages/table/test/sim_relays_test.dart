/// A table over modelled relays, where one seat reads only a relay the
/// other does not prefer: the half-deaf case that split a real table,
/// at the simulator's own level and on the virtual clock. The reader-
/// aware writing has each seat write where the others can read, so the
/// game plays out with nobody removed and the record verifies.
library;

import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('a seat that reaches only the relay the other does not prefer is still heard', () {
    final t = SimTable(humans: 2, seed: 7);
    t.net.relays = const ['ra', 'rb'];
    final a = t.signers[0].publicKey;
    final b = t.signers[1].publicKey;
    // a reaches both and prefers ra (first in order); b reaches only
    // rb. Nothing a writes to ra reaches b — until a learns from b's
    // heartbeat that b reads rb, and writes there instead.
    t.net.setReach(a, {'ra', 'rb'});
    t.net.setReach(b, {'rb'});

    t.start();
    final finished = t.run();
    expect(finished, isTrue, reason: 'the game finished:\n${t.clients.map((c) => c.describe()).join('\n')}');
    for (final c in t.clients) {
      expect(c.holders.whereType<HumanSeat>().length, 2, reason: 'nobody was removed');
      final v = verifyRecord(t.spec, c.record, juries: c.juries, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  });

  test('with no relays configured the bus is unchanged: a plain game finishes', () {
    final t = SimTable(humans: 2, seed: 9);
    expect(t.net.relays, isEmpty);
    t.start();
    expect(t.run(), isTrue);
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  });
}
