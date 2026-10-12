/// A table over modelled relays, where one seat reads only a relay the
/// other does not prefer: the half-deaf case that split a real table,
/// at the simulator's own level and on the virtual clock. The reader-
/// aware writing has each seat write where the others can read, so the
/// game plays out with nobody removed and the record verifies.
library;

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
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

  test('a write before any heartbeat reaches a peer that does not share its first relay', () {
    // Before a heartbeat has crossed, a writer has no idea what the
    // others read. Narrowing to one relay on that non-evidence would
    // have each client pick its own first, and when those differ,
    // nothing crosses, including the heartbeats that would say where
    // to write. A write floods until a peer says otherwise, so it
    // cannot fail that way.
    final clock = VirtualClock();
    final net = SimNetwork(clock)..relays = const ['ra', 'rb', 'rc'];
    final a = net.attach('A');
    final b = net.attach('B');
    net.setReach('A', {'ra', 'rc'});
    net.setReach('B', {'rb', 'rc'});
    expect(a.paths, ['ra', 'rc']);
    expect(b.paths, ['rb', 'rc']);
    var heard = 0;
    b.incoming.listen((_) => heard++);
    a.broadcast({'hello': 1});
    clock.advance(5000);
    expect(heard, 1, reason: "a's first write reached b on the relay they share");
  });

  test('once a peer has said what it reads, the write narrows to one relay they share', () {
    final clock = VirtualClock();
    final net = SimNetwork(clock)..relays = const ['ra', 'rb', 'rc'];
    final a = net.attach('A');
    final b = net.attach('B');
    net.setReach('A', {'ra', 'rc'});
    net.setReach('B', {'rb', 'rc'});
    var heard = 0;
    b.incoming.listen((_) => heard++);
    // b says what it reads: the one relay both reach is rc.
    a.heard('B', b.paths);
    a.broadcast({'hello': 1});
    clock.advance(5000);
    expect(heard, 1, reason: 'still delivered, now by the one relay they share');
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
