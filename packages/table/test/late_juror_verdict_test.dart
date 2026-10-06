/// A juror summoned late, and a seat the jury ruled out before it came.
///
/// A juror summoned a few hands in reads the record from the first
/// hand, carried forward by the table. Every carry sends every removal
/// in the record with the verdict that carried it, wherever the asker
/// stands, ahead of the juries those verdicts rest on — so a juror far
/// behind hears a removal's verdict before it knows the jury that gave
/// it. Dropped then, the verdict was a repeat ever after and never
/// read again: the juror stopped at the removal for good, counted the
/// seat a person's, and read every later hand's bot seats a seat short
/// of the table — one juror on a seat the table gave another
/// (docs/07-states.md). The chaos walk found it
/// (`tool/chaos.dart --sealed-only 4 --jurors 9 --sweep --twins`).
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a juror summoned after the jury ruled a seat out reads the table\'s bot seats', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 2);
    t.start();
    final a = t.clients.first;
    final quiet = t.people.last;
    // The other person goes quiet in the first hand's play. With two at
    // the table one is no majority, so the seat is the jury's to rule
    // out, and it is: the removal is on the record with its verdict.
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 2, limitMs: 10 * 60 * 1000), isTrue);
    quiet.depart(Exit.idle);
    bool ruledOut() => a.record.any((d) => d.removal && d.verdict != null && d.event.seat == quiet.client.mySeat);
    expect(t.clock.runUntil(ruledOut, limitMs: 10 * 60 * 1000), isTrue, reason: 'the jury ruled the seat out:\n${a.describe()}');
    // Two hands on, the seat a bot the jury holds.
    expect(t.clock.runUntil(() => a.game.handNumber >= 2 && a.game.phase == Phase.playing, limitMs: 30 * 60 * 1000), isTrue,
        reason: 'the table went on:\n${a.describe()}');
    final hand = a.game.handNumber;
    final first = a.juries.firstWhere((d) => d.event.hand == hand).event;

    // A juror nobody has heard of until now, summoned to this hand.
    final late = SimJuror(FakeSigner('late juror'), t.net, t.clock, crypto: crypto);
    t.jurors.add(late);
    late.summoned(t.spec, hand, first.jurors, juryId: first.id, first: true);
    final c = late.client!;
    expect(t.clock.runUntil(() => c.game.handNumber >= hand && c.botHolders(hand).isNotEmpty, limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the late juror reached the table\'s hand:\n${c.describe()}');
    expect(c.participants, a.participants, reason: 'the seat ruled out is out here too');
    expect(c.botHolders(hand), a.botHolders(hand), reason: 'the same juror on every bot seat');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
