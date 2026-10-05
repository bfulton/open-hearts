/// A hand's juries, and which of them the verifier deals the seats to.
///
/// The first jury drawn for a hand names each bot seat's holder, and a
/// redraw later in the hand moves the jury without moving the seats.
/// The draw is on the record: the one the first person's keys name
/// (sealed_to_draw_test.dart). A draw the hand carried besides — a
/// redraw too small to hold anything, with a lower id, say — moves no
/// seat for the verifier, from whatever place and with whatever id.
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

  test('nor is a redraw that could hold the seats, proposed from the first place there is', () {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, jurors: jurySize, target: 1);
    t.start();
    expect(t.run(limitMs: 30 * 60 * 1000), isTrue);
    final a = t.clients.first;
    final first = a.juries.firstWhere((d) => d.event.hand == 0);
    // Six strangers, proposed at the hand's first step by its first
    // seat, and read first in every order there is.
    TableEvent? redraw;
    for (var i = 0; redraw == null; i++) {
      final snapshot = [for (var k = 0; k < jurySize; k++) FakeSigner('elsewhere$i-$k').publicKey]..sort();
      final e = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.jury, body: {
        'hand': 0,
        'turn': TurnId.deal(0, 0, 0).index,
        'seat': 0,
        'jurors': drawJury(t.spec.seed, 0, snapshot),
        'snapshot': snapshot,
      });
      if (e.id.compareTo(first.event.id) < 0) redraw = e;
    }
    final me = {a.signer.publicKey};
    final juries = [...a.juries, Decision(turn: redraw.turn, event: redraw, witnesses: me, among: me, jury: true)];
    expect(compareJuries(juries.last, first), lessThan(0), reason: 'first by the table\'s own order');
    final v = verifyRecord(t.spec, a.record, juries: juries, crypto: crypto, releases: a.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
