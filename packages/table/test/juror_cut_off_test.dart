/// A juror cut off from the table, and the appeal it heard before.
///
/// A juror rules by the seat's presence to it: silent the table's
/// silence, the removal stands (docs/explanation/live-play.md). A juror that has lost the
/// table hears that silence from every seat, and cannot tell it from
/// its own. It went on ruling on an appeal heard minutes before: with
/// one person of two silent the turn was stuck, the jurors heard the
/// appeal, and then went offline; the person came back, played, and
/// the table went on. Two minutes after it last heard the seat, every
/// juror cut off ruled it out with an absence of its own signing,
/// which reached nobody but itself — and its record named the seat
/// absent at a turn the table had settled by the seat's own card, and
/// the table's records a leave later on. The chaos walk found it
/// (`tool/chaos.dart --seeds 150 --jurors 9 --sweep`, seed 1).
///
/// An appeal stands while the people say it, every ten seconds; a
/// juror rules only on one it has heard in the last half minute.
///
/// At a table that gives a person two minutes, as that one did: the
/// person comes back after the appeal and before the silence that
/// would have the jurors rule. At the standard's half minute the
/// jurors rule at once, on a seat already silent that long.
library;

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  test('a juror cut off after the appeal rules nothing on the turn the table settles without it', () {
    final t = SimTable(humans: 2, seed: 1, jurors: jurySize + 3, timing: TableTiming.unsaid);
    t.start();
    final a = t.clients.first;
    final quiet = t.people.last;
    final seat = quiet.client.mySeat!;
    final key = quiet.client.signer.publicKey;
    // The other person's connection drops at their own turn, and one
    // person of two is no majority: the turn is the jury's.
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1 && a.game.currentSeat == seat,
        limitMs: 10 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final turn = TurnId.play(hand, a.game.tricksPlayed * seatCount + a.game.trick.length);
    t.net.goOffline(key);
    final jury = [for (final j in t.jurors) if (j.client != null) j];
    expect(jury, isNotEmpty);
    expect(t.clock.runUntil(() => jury.every((j) => j.client!.describe().contains('appeals ($turn')), limitMs: 60 * 1000), isTrue,
        reason: 'every juror heard the appeal');

    // Then the whole jury loses the table, for good; the person comes
    // back and plays, and the people settle the turn without it.
    for (final j in jury) {
      j.depart(Exit.idle);
    }
    t.clock.advance(15000);
    t.net.comeOnline(key);
    expect(t.clock.runUntil(() => a.record.any((d) => !d.removal && d.turn == turn), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table settled the turn by the seat\'s own card:\n${a.describe()}');

    // Long past the table's two minutes of the seat's silence at the
    // jurors cut off.
    t.clock.advance(4 * 60 * 1000);
    for (final j in jury) {
      final out = j.client!.record.where((d) => d.removal && d.event.seat == seat).toList();
      expect(out, isEmpty, reason: 'juror ${j.signer.publicKey.substring(0, 4)}, cut off, ruled the seat out at ${out.map((d) => d.turn)}');
      expect(j.verdicts, 0, reason: 'and gave no verdict at all');
    }
    expect(a.record.where((d) => d.removal && d.event.seat == seat), isEmpty, reason: 'the seat is still a person\'s');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
