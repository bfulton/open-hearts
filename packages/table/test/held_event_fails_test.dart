/// A held event that throws when it is taken up does not cost the ones
/// held with it (client.dart, _drainFuture): each is taken up on its
/// own, the failure is traced, and it is thrown once the rest are in, as
/// it would have been had it arrived just then.
library;

import 'dart:async';

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  test('a held event that throws is traced and thrown once, and the ones held with it are taken up', () {
    late SimTable t;
    late TableClient c;
    final lines = <String>[];
    final thrown = <Object>[];
    var recordAtThrow = -1;
    // What a client's handlers throw reaches the zone it listens in.
    runZonedGuarded(() {
      t = SimTable(humans: 4, seed: 3);
      c = t.clients.first;
      c.log = lines.add;
      t.start();
    }, (error, stack) {
      thrown.add(error);
      recordAtThrow = c.record.length;
    });

    // One play by another seat, with the play after it someone else's
    // too, is held back from this side for twenty seconds, every copy:
    // the other three settle it and play on, and what they play reaches
    // this side ahead of its turn and is held there.
    String? held;
    var heldAt = 0;
    final early = <String>{};
    t.net.steer = (from, to, m) {
      if (to != c.signer.publicKey || from == c.signer.publicKey) return null;
      if (held != null && m['id'] == held) return heldAt + 20000 - t.clock.nowMs;
      if (m['kind'] != 'play' || m['author'] != from) return null;
      final body = m['body'] as Map;
      final turn = body['turn'] as int;
      if (held == null) {
        if (turn < 12 || ((body['seat'] as int) + 1) % t.clients.length == c.mySeat) return null;
        held = m['id'] as String;
        heldAt = t.clock.nowMs;
        return 20000;
      }
      if (t.clock.nowMs < heldAt + 19000) early.add(m['id'] as String);
      return null;
    };
    // The first witness this side sends of one of those, once the held
    // play is in: the drain's, taking it up. Its write fails, as a
    // socket's can.
    var recordAtFailure = -1;
    String? failed;
    t.net.onSend = (from, m) {
      if (failed != null || from != c.signer.publicKey || m['kind'] != 'witness') return;
      final of = (m['body'] as Map)['event'];
      if (!early.contains(of) || !c.record.any((d) => d.event.id == held)) return;
      failed = of as String;
      recordAtFailure = c.record.length;
      throw StateError('the line went down');
    };

    expect(t.clock.runUntil(() => thrown.isNotEmpty, limitMs: 120000), isTrue, reason: 'the drain met the failure');
    expect(early.length, greaterThanOrEqualTo(2), reason: 'plays were held behind the one held back: $early');
    expect(thrown, [isA<StateError>()], reason: 'thrown once, and it is the one made');
    expect(lines.where((l) => l.contains('held play ${failed!.substring(0, 6)} failed: Bad state: the line went down')), hasLength(1),
        reason: 'and traced where it failed');
    expect(recordAtThrow, greaterThan(recordAtFailure), reason: 'thrown after the rest were taken up, not where it failed');
    for (final e in early) {
      expect(c.record.any((d) => d.event.id == e), isTrue, reason: 'every play held with it is in: ${e.substring(0, 6)}');
    }

    t.net.onSend = null;
    t.net.steer = null;
    expect(t.run(), isTrue, reason: 'and the game goes on to its end');
    expect(c.failure, isNull);
    t.stop();
  });
}
