/// A hand's juries, read in one order by the table and the verifier.
///
/// The first jury drawn for a hand names each bot seat's holder, and a
/// redraw later in the hand moves the jury without moving the seats.
/// The table reads "first" by where each draw was proposed; the
/// verifier went by event id. A hand drawn again twice at one trick,
/// with the lower id on a redraw of three — too few to hold anything —
/// was then read by the verifier as having no jury able to hold its
/// bot seats: it took their keys for anybody's to compute and turned
/// down a record the table had played by the first draw. Found by the
/// chaos walk with nine strangers to draw from (sealed seeds 1 and 2).
library;

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a redraw with the lower id is still not the draw the seats were dealt to', () {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, jurors: jurySize, target: 1);
    t.start();
    expect(t.run(limitMs: 30 * 60 * 1000), isTrue);
    final a = t.clients.first;
    final played = verifyRecord(t.spec, a.record, juries: a.juries, crypto: crypto, releases: a.releases);
    expect(played.ok && played.complete, isTrue, reason: played.reason);
    final first = a.juries.firstWhere((d) => d.event.hand == 0);
    // A redraw of three strangers at the hand's tenth play, proposed and
    // carried by the one person at the table, whose id sorts first.
    TableEvent? redraw;
    for (var i = 0; redraw == null; i++) {
      final snapshot = [for (var k = 0; k < 3; k++) FakeSigner('stranger$i-$k').publicKey]..sort();
      final e = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.jury, body: {
        'hand': 0,
        'turn': TurnId.play(0, 9).index,
        'seat': 0,
        'jurors': drawJury(t.spec.seed, 0, snapshot),
        'snapshot': snapshot,
      });
      if (e.id.compareTo(first.event.id) < 0) redraw = e;
    }
    final me = {a.signer.publicKey};
    final juries = [...a.juries, Decision(turn: redraw.turn, event: redraw, witnesses: me, among: me, jury: true)];
    final v = verifyRecord(t.spec, a.record, juries: juries, crypto: crypto, releases: a.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
