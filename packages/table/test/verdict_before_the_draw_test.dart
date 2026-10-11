/// A seat ruled out by the jury in force at a hand before the hand's
/// own jury carried.
///
/// A jury stays in force until a later one carries: a table of two
/// with one gone quiet cannot carry a new one, and that is when it
/// needs the old (docs/explanation/live-play.md). So a person who goes quiet
/// after their last card of a hand is ruled out at the next hand's
/// pass by the last hand's jury. With the seat gone, the one person
/// left is the table's majority and carries the hand's own draw, and
/// the juror who ruled need not be in it. The verifier read the jurors
/// of a hand as those in force at the end of the record — the hand's
/// own, once it had any — and turned the removal down as carried by
/// nobody: "a absent of seat 0 at h1/pass without a majority behind it
/// (1 of 2)". The chaos walk found it
/// (`tool/chaos.dart --seeds 150 --jurors 9 --sweep`, seed 137).
///
/// Only up to there, though. Once the hand's own jury has carried, a
/// client takes no verdict from a juror outside it, so a record with
/// one past the turn the hand's own carried at is not a table's, and
/// the verifier turns it down.
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

  test('and not past the turn the hand\'s own jury carried at', () {
    final t = SimTable(humans: 2, seed: 2, jurors: jurySize + 3);
    t.start();
    final a = t.clients.first;
    final quiet = t.people.last;
    final seat = quiet.client.mySeat!;
    bool lastCard() => a.record.where((d) => !d.removal && d.turn.hand == 0 && d.event.kind == EventKind.play && d.event.seat == seat).length == 13;
    expect(t.clock.runUntil(lastCard, limitMs: 10 * 60 * 1000), isTrue);
    quiet.depart(Exit.idle);
    expect(t.run(), isTrue, reason: a.describe());
    final me = a.signer.publicKey;
    expect(verifyRecord(t.spec, a.record, juries: a.juries).ok, isTrue, reason: 'as played, the record verifies');

    // A hand with a jury of its own, an earlier hand's juror outside
    // it, and this person's own moves in the hand before and after the
    // turn the hand's own jury carried at.
    Set<String> jurorsOf(int hand) => {for (final d in a.juries.where((d) => d.event.hand == hand)) ...d.event.jurors};
    ({int hand, TurnId carried, SimJuror outside, Decision before, Decision after})? found;
    for (final hand in {for (final d in a.juries) d.event.hand}.where((h) => h > 0).toList()..sort()) {
      final carried = a.juries.where((d) => d.event.hand == hand).map((d) => d.turn).reduce((x, y) => x.position <= y.position ? x : y);
      final earlier = [for (final d in a.juries) if (d.event.hand < hand) d.event.hand].fold(-1, (x, y) => x > y ? x : y);
      final outside = t.jurors.where((j) => jurorsOf(earlier).contains(j.signer.publicKey) && !jurorsOf(hand).contains(j.signer.publicKey));
      final mine = a.record.where((d) => !d.removal && d.turn.hand == hand && d.event.author == me);
      final before = mine.where((d) => d.turn.position <= carried.position);
      final after = mine.where((d) => d.turn.position > carried.position);
      if (outside.isEmpty || before.isEmpty || after.isEmpty) continue;
      found = (hand: hand, carried: carried, outside: outside.first, before: before.first, after: after.first);
      break;
    }
    expect(found, isNotNull, reason: 'a hand to try it on');
    final f = found!;

    // The move, carried by nobody but a verdict.
    Verification ruledBy(Signer juror, Decision d) {
      final verdict = TableEvent.sign(juror, table: t.spec.id, kind: EventKind.verdict, body: {
        'hand': d.turn.hand,
        'turn': d.turn.index,
        'seat': d.event.seat,
        'side': 'action',
        'event': d.event.toJson(),
      });
      final forged = Decision(turn: d.turn, event: d.event, witnesses: const {}, among: d.among, verdict: verdict);
      final record = [for (final x in a.record) identical(x, d) ? forged : x];
      return verifyRecord(t.spec, record, juries: a.juries);
    }

    final own = t.jurors.firstWhere((j) => jurorsOf(f.hand).contains(j.signer.publicKey));
    expect(ruledBy(own.signer, f.after).ok, isTrue, reason: 'a juror of the hand rules any turn of it');
    expect(ruledBy(f.outside.signer, f.before).ok, isTrue,
        reason: 'the earlier hand\'s juror rules ${f.before.turn}, at or before ${f.carried}, where the hand\'s own carried');
    final past = ruledBy(f.outside.signer, f.after);
    expect(past.ok, isFalse, reason: 'the earlier hand\'s juror ruling ${f.after.turn}, past ${f.carried}');
    expect(past.reason, contains('without a majority behind it'));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
