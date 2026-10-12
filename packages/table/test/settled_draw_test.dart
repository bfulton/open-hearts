/// The draw prefers jurors that have stayed.
///
/// A hand's escrow rests on the jurors it drew still being there when
/// a bot seat has to be opened, and the lever on that is who is drawn
/// rather than how many (docs/explanation/live-play.md). A
/// proposer may narrow its own candidates as it likes, because what
/// the table checks of a proposal is that each juror is somebody *it*
/// has seen lately, over a far wider window.
library;

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  /// A table whose jurors have all been online a while, and then some
  /// newcomers who have not.
  ({SimTable table, List<SimJuror> old, List<SimJuror> fresh}) settled({int oldOnes = 6, int freshOnes = 6}) {
    final t = SimTable(humans: 4, seed: 5, jurors: oldOnes, withPresence: true);
    t.start();
    // Long enough that the first lot are settled by anyone's measure.
    t.clock.advance(TableClient.jurySettledMs + 20000);
    final old = [...t.jurors];
    final fresh = <SimJuror>[];
    for (var i = 0; i < freshOnes; i++) {
      final j = SimJuror(FakeSigner('fresh$i'), t.net, t.clock, crypto: null);
      t.jurors.add(j);
      fresh.add(j);
      t.presence!.register(j);
    }
    // A beat or two, so the newcomers are online but only just.
    t.clock.advance(11000);
    return (table: t, old: old, fresh: fresh);
  }

  test('a jury is drawn from those who have stayed, while there are enough of them', () {
    final s = settled();
    final keys = {for (final j in s.old) j.signer.publicKey};
    final newcomers = {for (final j in s.fresh) j.signer.publicKey};
    final p = s.table.presence!;
    expect(p.online(withinMs: 15000), containsAll(newcomers), reason: 'the newcomers are online');
    expect(p.settled(withinMs: 15000, forMs: TableClient.jurySettledMs).intersection(newcomers), isEmpty,
        reason: 'and settled is not the same thing');

    s.table.clock.runUntil(() => s.table.clients.first.juries.isNotEmpty, limitMs: 3 * 60 * 1000);
    final jury = s.table.clients.first.juries.first.event.jurors.toSet();
    expect(jury, isNotEmpty);
    expect(jury.difference(keys), isEmpty, reason: 'drawn from the ones that had stayed: $jury');
    s.table.stop();
  });

  test('and from whoever is there when too few have stayed, since a jury beats none', () {
    // Nobody settled at all: every juror arrives moments before the
    // table needs one.
    final t = SimTable(humans: 4, seed: 6, jurors: 6, withPresence: true);
    t.start();
    t.clock.advance(11000);
    final p = t.presence!;
    expect(p.settled(withinMs: 15000, forMs: TableClient.jurySettledMs), isEmpty,
        reason: 'nobody has been here long enough');

    t.clock.runUntil(() => t.clients.first.juries.isNotEmpty, limitMs: 3 * 60 * 1000);
    expect(t.clients.first.juries.first.event.jurors, isNotEmpty, reason: 'a jury was still drawn');
    t.stop();
  });
}
