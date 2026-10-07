/// A seat ruled out by the jury in force at a hand before the hand's
/// own jury carried.
///
/// A jury stays in force until a later one carries: a table of two
/// with one gone quiet cannot carry a new one, and that is when it
/// needs the old (docs/04-live-play.md). So a person who goes quiet
/// after their last card of a hand is ruled out at the next hand's
/// pass by the last hand's jury. With the seat gone, the one person
/// left is the table's majority and carries the hand's own draw, and
/// the juror who ruled need not be in it. The verifier read the jurors
/// of a hand as those in force at the end of the record — the hand's
/// own, once it had any — and turned the removal down as carried by
/// nobody: "a absent of seat 0 at h1/pass without a majority behind it
/// (1 of 2)". The chaos walk found it
/// (`tool/chaos.dart --seeds 150 --jurors 9 --sweep`, seed 137).
library;

import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('a removal ruled by the last hand\'s jury verifies once the hand carries its own', () {
    final t = SimTable(humans: 2, seed: 2, jurors: jurySize + 3);
    t.start();
    final a = t.clients.first;
    final quiet = t.people.last;
    final seat = quiet.client.mySeat!;
    // The other person goes quiet the moment their last card of the
    // first hand has settled: their seat's next turn is the next
    // hand's pass, and that hand cannot carry a jury of its own while
    // they still count.
    bool lastCard() => a.record.where((d) => !d.removal && d.turn.hand == 0 && d.event.kind == EventKind.play && d.event.seat == seat).length == 13;
    expect(t.clock.runUntil(lastCard, limitMs: 10 * 60 * 1000), isTrue);
    quiet.depart(Exit.idle);

    Decision? ruledOut() => a.record.where((d) => d.removal && d.event.seat == seat).firstOrNull;
    expect(t.clock.runUntil(() => ruledOut() != null, limitMs: 10 * 60 * 1000), isTrue, reason: 'the jury ruled the seat out:\n${a.describe()}');
    final out = ruledOut()!;
    expect(out.turn.hand, 1, reason: 'at the next hand');
    expect(out.verdict, isNotNull, reason: 'by a verdict: one person of two is no majority');
    final judge = out.verdict!.author;
    expect(a.juries.where((d) => d.event.hand == 0).expand((d) => d.event.jurors), contains(judge), reason: 'a juror of the first hand');

    expect(t.clock.runUntil(() => a.juries.any((d) => d.event.hand == 1), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the person left carried the hand\'s own draw:\n${a.describe()}');
    final own = a.juries.where((d) => d.event.hand == 1).expand((d) => d.event.jurors);
    expect(own, isNot(contains(judge)), reason: 'one the juror who ruled is not in');

    final v = verifyRecord(t.spec, a.record, allowPartial: true, juries: a.juries);
    expect(v.ok, isTrue, reason: v.reason);
    // And on to the end, the seat a bot.
    expect(t.run(), isTrue, reason: a.describe());
    final end = verifyRecord(t.spec, a.record, juries: a.juries);
    expect(end.ok && end.complete, isTrue, reason: end.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
