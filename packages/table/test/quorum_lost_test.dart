/// A hand nobody left can open, and the game that ends for it.
///
/// A held bot seat is opened by its own juror, or by any
/// [escrowThreshold] of the jurors holding a piece of its secret; a
/// departed person's, by a person's piece and a juror's. With the
/// jurors that hold them gone mid-hand, the seat cannot be opened by
/// anyone at all, and the hand cannot go on. The table used to wait
/// for them for good. Giving the hand up instead would throw away a
/// hand whose cards have been seen, which enough jurors leaving
/// together could do to order. So the game ends — a connection
/// failure, "juror quorum lost", unscored — once the table has been
/// stopped there for as long as a person is given before the table
/// removes them for silence (docs/04-live-play.md, "When quorum is
/// lost anyway").
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  // With jurors online beyond the jury, the table draws again the
  // moment it stops hearing its own — and a juror drawn after the
  // pieces' holders went holds nothing: a newcomer is given its piece
  // by [escrowThreshold] of the holders, and there are not that many
  // left to give it. The table counted the newcomers as custodians
  // anyway, took the seat for one the jury could still open, and sat
  // at its turn saying nothing, for good.
  test('the whole jury gone mid-hand: the table waits for it, then ends the game, juror quorum lost', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final hand = c.game.handNumber;
    final drawn = c.juries.last.event.jurors;
    for (final j in drawn) {
      t.net.goOffline(j);
    }
    expect(t.clock.runUntil(() => c.pause == Pause.waitingForJury, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table said it was waiting for the jury:\n${c.describe()}');
    final pausedAt = t.clock.nowMs;
    expect(c.botHolders(hand).keys, contains(c.game.currentSeat), reason: 'at a held seat');
    // And still says so once the jury drawn again is heard from.
    t.clock.advance(30 * 1000);
    expect(c.custodiansOf(hand).length, greaterThan(drawn.length), reason: 'a jury was drawn again');
    expect(c.tableState, TableState.pausedForJury, reason: 'with nothing in it to open the seat with:\n${c.describe()}');

    expect(t.clock.runUntil(() => t.clients.every((c) => c.tableState == TableState.failed), limitMs: 4 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${c.describe()}');
    expect(t.clock.nowMs - pausedAt, greaterThanOrEqualTo(c.silenceAfterMs), reason: 'and not before the table had waited');
    for (final c in t.clients) {
      expect(c.failure, Failure.jurorQuorumLost);
      expect(c.done, isFalse, reason: 'unfinished, so unscored');
      final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
    }

    // And that is the end of it here: nothing more said, whoever comes
    // back. The jury returning now does not reopen a game its players
    // have been told is over.
    final said = c.heartbeatsSent;
    final record = c.record.length;
    for (final j in drawn) {
      t.net.comeOnline(j);
    }
    t.clock.advance(60 * 1000);
    expect(c.heartbeatsSent, said, reason: 'a table that has ended goes quiet');
    expect(c.record.length, record);
    expect(c.tableState, TableState.failed);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The allowance is the whole of it: the jury back inside it and the
  // table goes on as it always did (jury_gone_test.dart).
  test('the jury back inside the two minutes: the table goes on, and does not end', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final hand = c.game.handNumber;
    final drawn = c.juries.last.event.jurors;
    for (final j in drawn) {
      t.net.goOffline(j);
    }
    expect(t.clock.runUntil(() => c.pause == Pause.waitingForJury, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table said it was waiting for the jury:\n${c.describe()}');
    t.clock.advance(c.silenceAfterMs - 20 * 1000);
    expect(c.tableState, TableState.pausedForJury, reason: 'still waiting, not ended: ${c.describe()}');
    for (final j in drawn) {
      t.net.comeOnline(j);
    }
    expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the table played the hand out once its jury was back:\n${c.describe()}');
    for (final c in t.clients) {
      expect(c.failure, isNull, reason: c.describe());
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A person's seat is opened with a person's piece and a juror's, so
  // at a table of four people it is the jury's piece that goes with
  // the jury: the leaver's hand stays shut, and its bot never moves.
  test('a person leaving mid-hand with the jury gone: their hand cannot be opened, and the game ends', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing && c.game.tricksPlayed >= 1, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the hand was dealt and a trick played');
    expect(c.juries, isNotEmpty, reason: 'a table of four people draws a jury too, for the escrow');
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    t.clock.advance(35 * 1000);
    t.clients.last.leave();
    expect(t.clock.runUntil(() => c.pause == Pause.openingHand, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the table stopped at the leaver\'s seat, its hand not open:\n${c.describe()}');
    final stoppedAt = t.clock.nowMs;
    final seat = c.stalled.values.first;
    expect(t.clock.runUntil(() => c.failure != null, limitMs: 4 * 60 * 1000), isTrue, reason: 'the game ended:\n${c.describe()}');
    expect(t.clock.nowMs - stoppedAt, greaterThanOrEqualTo(c.silenceAfterMs - 1000));
    expect(c.failure, Failure.jurorQuorumLost);
    expect(c.failedAt?.seat, seat);
    for (final c in t.clients.take(3)) {
      expect(t.clock.runUntil(() => c.failure != null, limitMs: 60 * 1000), isTrue, reason: 'at every side still there: ${c.describe()}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
