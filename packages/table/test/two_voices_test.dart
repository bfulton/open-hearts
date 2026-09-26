/// A bot seat played twice, the same card by two voices.
///
/// A seat a juror holds is played by that juror, or — once the table
/// gives it to the escrow for its juror's silence or slowness — by the
/// first of the hand's custodians still about. Which peers have given
/// it up is each peer's own judgement, so the two overlap: a juror
/// late with its move comes back and says it, as doc 04 lets it,
/// while the custodian says the same card for it. Two events, the same
/// move. Each peer witnessed whichever came first, a witness for the
/// other was kept aside and never counted, and at a table of two the
/// turn needed both of them: neither move could carry, and nothing
/// saw that as the deadlock it was, since only a person's seat was
/// ever looked at for one. The table sat at that card for good.
///
/// Found by `tool/explore.dart` (one lost witness that made a juror
/// late); pinned here by making the two voices on purpose and letting
/// each person hear a different one first.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('the same card said for a bot seat by its juror and a custodian is settled by the jury, not waited on', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    final a = t.clients.first;
    final b = t.clients.elementAt(1);
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && b.game.phase == Phase.playing, limitMs: 5 * 60 * 1000),
        isTrue);
    final hand = a.game.handNumber;
    final held = a.botHolders(hand);
    // The held seat that plays soonest from here.
    final seat = [for (var i = 0; i < seatCount; i++) (a.game.currentSeat! + i) % seatCount].firstWhere(held.containsKey);
    final holder = held[seat]!;
    t.net.doze(holder);

    // Each person hears a different voice first: the custodian's card
    // late to b, the juror's late to a — every copy of each held until
    // well after the juror, woken, has said its card again (its repeat
    // backs off to eight seconds by then).
    String? custodian;
    int? until;
    t.net.steer = (from, to, message) {
      if (message['kind'] != 'play') return null;
      final body = message['body'] as Map<String, Object?>;
      if (body['hand'] != hand || body['seat'] != seat) return null;
      final author = message['author'] as String;
      if (author != holder && custodian == null) {
        custodian = author;
        until = t.clock.nowMs + 15000;
        t.clock.schedule(100, () => t.net.wake(holder));
      }
      final late = author == holder ? a.signer.publicKey : b.signer.publicKey;
      if (to != late || until == null || t.clock.nowMs >= until!) return null;
      return until! - t.clock.nowMs;
    };

    final through = t.clock.runUntil(() => [a, b].every((c) => c.game.tricksPlayed >= 1), limitMs: 3 * 60 * 1000);
    expect(custodian, isNotNull, reason: 'a custodian said the seat\'s card');
    expect(through, isTrue, reason: 'the table moved past the seat:\n${a.describe()}\n${b.describe()}');
    final da = a.record.where((d) => d.turn.hand == hand && d.turn.isPlay && d.event.seat == seat).first;
    final db = b.record.where((d) => d.turn.hand == hand && d.turn.isPlay && d.event.seat == seat).first;
    expect(db.event.id, da.event.id, reason: 'both hold the same one of the two');
    for (final c in [a, b]) {
      final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
