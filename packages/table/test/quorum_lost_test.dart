/// A hand nobody left can open, and the game that ends for it.
///
/// A held bot seat is opened by its own juror, or by any
/// [escrowThreshold] of the jurors holding a piece of its secret; a
/// departed person's, by a person's piece and a juror's. With the
/// jurors that hold them gone mid-hand, the seat cannot be opened by
/// anyone at all, and the hand cannot go on. Giving the hand up would throw away a
/// hand whose cards have been seen, which enough jurors leaving
/// together could do to order. So the game ends — a connection
/// failure, "juror quorum lost", unscored — once the table has been
/// stopped there for twenty seconds ([TableClient.quorumLostAfterMs];
/// docs/04-live-play.md).
///
/// The same for a turn only the jury can settle — a play met by a
/// boot, or a table of two with one of them gone — once none of its
/// jurors is left to rule, rather than pausing for the jury for good
/// (docs/07-states.md). A side that hears too
/// little of the table to tell the jury gone from its own connection
/// gone waits until everyone it cannot hear has been silent as long as
/// a person is given. And the ending is said: the other side ends with
/// it, and a juror still following stops.
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
    // And still says so once the jury drawn again is heard from, which
    // is moments after the pause.
    t.clock.advance(TableClient.quorumLostAfterMs ~/ 2);
    expect(c.custodiansOf(hand).length, greaterThan(drawn.length), reason: 'a jury was drawn again');
    expect(c.tableState, TableState.pausedForJury, reason: 'with nothing in it to open the seat with:\n${c.describe()}');

    expect(t.clock.runUntil(() => t.clients.every((c) => c.tableState == TableState.failed), limitMs: 4 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${c.describe()}');
    expect(t.clock.nowMs - pausedAt, greaterThanOrEqualTo(TableClient.quorumLostAfterMs), reason: 'and not before the table had waited');
    for (final c in t.clients) {
      expect(c.failure, Failure.jurorQuorumLost);
      expect(c.done, isFalse, reason: 'unfinished, so unscored');
      // On the record, where both people could say so at the turn
      // (ended_on_record_test.dart).
      expect(c.record.last.event.kind, EventKind.ended);
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.ended, isTrue, reason: v.reason);
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
  test('the jury back inside the twenty seconds: the table goes on, and does not end', () {
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
    t.clock.advance(TableClient.quorumLostAfterMs ~/ 2);
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
    expect(t.clock.nowMs - stoppedAt, greaterThanOrEqualTo(TableClient.quorumLostAfterMs));
    expect(c.failure, Failure.jurorQuorumLost);
    expect(c.failedAt?.seat, seat);
    for (final c in t.clients.take(3)) {
      expect(t.clock.runUntil(() => c.failure != null, limitMs: 60 * 1000), isTrue, reason: 'at every side still there: ${c.describe()}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The first person's play turn, with the jury drawn: whose it is,
  // and the other person.
  ({TableClient x, TableClient y, TurnId turn}) atAPlayTurn(SimTable t) {
    final a = t.clients.first, b = t.clients.last;
    expect(
        t.clock.runUntil(
            () => a.juries.isNotEmpty && a.game.phase == Phase.playing && {a.mySeat, b.mySeat}.contains(a.game.currentSeat),
            limitMs: 5 * 60 * 1000),
        isTrue,
        reason: 'a person\'s turn to play, the jury drawn');
    final x = a.game.currentSeat == a.mySeat ? a : b;
    return (x: x, y: x == a ? b : a, turn: TurnId.play(a.game.handNumber, a.game.tricksPlayed * 4 + a.game.trick.length));
  }

  // Two people, the jury gone, and
  // a play one of them never received, so booted by them — one vote
  // each, and only a juror can settle it.
  test('a play met by a boot with the whole jury gone: nobody can rule on it, and the game ends at both sides', () {
    final t = SimTable(humans: 2, seed: 3, jurors: jurySize);
    t.start();
    final (:x, :y, :turn) = atAPlayTurn(t);
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    // The play kept from the other person until they have booted it.
    t.net.steer = (from, to, message) =>
        from == x.signer.publicKey && to == y.signer.publicKey && message['kind'] == 'play' && y.turnStateOf(turn) != TurnState.contested
            ? -1
            : null;
    expect(t.clock.runUntil(() => x.stuckSplit == turn && y.stuckSplit == turn, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the turn split, a vote each:\n${x.describe()}\n${y.describe()}');
    final splitAt = t.clock.nowMs;
    expect(x.tableState, TableState.pausedForJury);
    expect(t.clock.runUntil(() => x.failure != null && y.failure != null, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${x.describe()}\n${y.describe()}');
    expect(t.clock.nowMs - splitAt, greaterThanOrEqualTo(TableClient.quorumLostAfterMs), reason: 'and not before the table had waited');
    for (final c in [x, y]) {
      expect(c.failure, Failure.jurorQuorumLost);
      expect(c.failedAt?.turn, turn);
      expect(c.done, isFalse, reason: 'unfinished, so unscored');
      // Each ends for itself. Both voices at the turn are spent, one on
      // the play and one on the boot, and with no jury there is nobody
      // to put the end on the record: each record stops at the turn.
      expect(c.record.any((d) => d.event.kind == EventKind.ended), isFalse);
      final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.ended, isFalse);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The one left cannot tell the other gone from its
  // own connection gone, so it waits the silence a person is given:
  // were it the one cut off, that is how long the table would take to
  // go on without it.
  test('the last person at a table of two, with the jury gone: the game ends once the other has been silent two minutes', () {
    final t = SimTable(humans: 2, seed: 3, jurors: jurySize);
    t.start();
    final (:x, :y, :turn) = atAPlayTurn(t);
    t.net.goOffline(y.signer.publicKey);
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    final goneAt = t.clock.nowMs;
    t.clock.advance(90 * 1000);
    expect(x.tableState, TableState.pausedForJury, reason: 'waiting, and saying so:\n${x.describe()}');
    expect(x.failure, isNull, reason: 'not while the other might be the one cut off');
    expect(t.clock.runUntil(() => x.failure != null, limitMs: 3 * 60 * 1000), isTrue, reason: 'the game ended:\n${x.describe()}');
    expect(t.clock.nowMs - goneAt, greaterThanOrEqualTo(120 * 1000 + TableClient.quorumLostAfterMs),
        reason: 'the silence a person is given, and the twenty seconds after it');
    expect(x.failure, Failure.jurorQuorumLost);
    expect(x.failedAt?.turn, turn);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The one left hears nobody, and a jury that
  // is cut off from it for a minute is not a jury gone: it may already
  // have ruled, as here, and its ruling is on its way.
  test('the last person at a table of two, cut off from a jury still there: it waits for the ruling, and plays on', () {
    final t = SimTable(humans: 2, seed: 3, jurors: jurySize);
    t.start();
    final (:x, :y, :turn) = atAPlayTurn(t);
    t.net.goOffline(y.signer.publicKey);
    final jurors = [for (final j in t.jurors) j.signer.publicKey];
    t.clock.advance(100 * 1000);
    for (final j in jurors) {
      t.net.cut(j, x.signer.publicKey);
    }
    t.clock.advance(60 * 1000);
    expect(x.failure, isNull, reason: 'not while the jury might yet be heard:\n${x.describe()}');
    for (final j in jurors) {
      t.net.uncut(j, x.signer.publicKey);
    }
    expect(t.clock.runUntil(() => x.turnStateOf(turn) == TurnState.settledByAction, limitMs: 60 * 1000), isTrue,
        reason: 'the jury\'s ruling carried the play:\n${x.describe()}');
    expect(x.failure, isNull);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Cut off from each other, both people pause
  // for the jury — at a table of two that is who settles what one of
  // them cannot. Back in touch, the pause stays up until a decision
  // lands, but the turn is theirs to settle again: the play only wants
  // the other's backing, however late the copy that brings it.
  test('two people cut off from each other a moment, the jury gone: back in touch, the play carries and the game goes on', () {
    // A bank long enough that the other's clock does not boot the play
    // before its late copy comes: this is about the pause, not the
    // clock.
    final t = SimTable(humans: 2, seed: 3, jurors: jurySize, timeBank: const TimeBank(bankMs: 5 * 60 * 1000));
    t.start();
    final first = t.clients.first;
    expect(t.clock.runUntil(() => first.juries.isNotEmpty, limitMs: 60 * 1000), isTrue, reason: 'a jury drawn');
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    t.clock.advance(40 * 1000);
    final (:x, :y, :turn) = atAPlayTurn(t);
    final opened = t.clock.nowMs;
    t.net.partition([{x.signer.publicKey}, {y.signer.publicKey}]);
    t.net.steer = (from, to, message) =>
        from == x.signer.publicKey && to == y.signer.publicKey && message['kind'] == 'play' && t.clock.nowMs < opened + 45 * 1000
            ? -1
            : null;
    t.clock.advance(16 * 1000);
    expect(x.tableState, TableState.pausedForJury, reason: 'cut off, and waiting on the jury:\n${x.describe()}');
    t.net.heal();
    expect(t.clock.runUntil(() => x.turnStateOf(turn) == TurnState.settledByAction && y.turnStateOf(turn) == TurnState.settledByAction,
            limitMs: 90 * 1000),
        isTrue,
        reason: 'the play carried once its copy came:\n${x.describe()}\n${y.describe()}');
    for (final c in [x, y]) {
      expect(c.failure, isNull, reason: c.describe());
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a person cut off inside the silence they are given, the jury gone: back, and the game goes on', () {
    final t = SimTable(humans: 2, seed: 3, jurors: jurySize);
    t.start();
    final (:x, :y, :turn) = atAPlayTurn(t);
    t.net.goOffline(y.signer.publicKey);
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    t.clock.advance(90 * 1000);
    expect(x.tableState, TableState.pausedForJury);
    expect(y.tableState, TableState.pausedForJury, reason: 'and the one cut off, hearing nobody, waits too:\n${y.describe()}');
    t.net.comeOnline(y.signer.publicKey);
    expect(t.clock.runUntil(() => x.turnStateOf(turn) == TurnState.settledByAction && y.turnStateOf(turn) == TurnState.settledByAction,
            limitMs: 60 * 1000),
        isTrue,
        reason: 'the play carried once they heard each other:\n${x.describe()}\n${y.describe()}');
    t.clock.advance(60 * 1000);
    for (final c in [x, y]) {
      expect(c.failure, isNull, reason: c.describe());
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A juror left holding one
  // piece of a seat that takes two follows a game that has ended: it
  // hears the people say so and stops, rather than waiting until it
  // has heard nobody for five minutes.
  test('the one juror left, when the game ends: the people say so, it stops, and they end together', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final hand = c.game.handNumber;
    final drawn = c.juries.last.event.jurors;
    final held = c.botHolders(hand).values.toSet();
    final kept = drawn.firstWhere((k) => !held.contains(k));
    // Out of one person's hearing ten seconds before the other's, so
    // that their own clocks would end the game ten seconds apart.
    for (final j in drawn.where((k) => k != kept)) {
      t.net.cut(j, c.signer.publicKey);
    }
    t.clock.advance(10 * 1000);
    for (final j in drawn.where((k) => k != kept)) {
      t.net.goOffline(j);
    }
    final juror = t.jurors.firstWhere((j) => j.signer.publicKey == kept).client!;
    expect(t.clock.runUntil(() => t.clients.any((c) => c.failure != null), limitMs: 4 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${c.describe()}');
    final first = t.clock.nowMs;
    expect(t.clock.runUntil(() => t.clients.every((c) => c.failure != null), limitMs: 60 * 1000), isTrue);
    expect(t.clock.nowMs - first, lessThan(2000), reason: 'the other side ended on hearing it, not on its own clock');
    expect(t.clock.runUntil(() => !juror.serving, limitMs: 10 * 1000), isTrue,
        reason: 'the juror left heard it and stopped:\n${juror.describe()}');
    expect(juror.failure, Failure.jurorQuorumLost);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The last person, stopped at a held seat,
  // and one juror still heard who holds one piece of a seat that takes
  // two. It cannot open the seat, so it does not keep the game
  // going.
  test('the last person, with one juror left who cannot open the seat: the game ends all the same', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first, other = t.clients.last;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final hand = c.game.handNumber;
    final held = c.botHolders(hand);
    expect(t.clock.runUntil(() => held.containsKey(c.game.currentSeat), limitMs: 60 * 1000), isTrue, reason: 'a held seat\'s turn');
    final drawn = c.juries.last.event.jurors;
    final kept = drawn.firstWhere((k) => !held.values.contains(k));
    for (final j in drawn.where((k) => k != kept)) {
      t.net.goOffline(j);
    }
    t.net.goOffline(other.signer.publicKey);
    final goneAt = t.clock.nowMs;
    t.clock.advance(90 * 1000);
    expect(c.failure, isNull, reason: 'not while the other might be the one cut off');
    expect(t.clock.runUntil(() => c.failure != null, limitMs: 3 * 60 * 1000), isTrue, reason: 'the game ended:\n${c.describe()}');
    expect(t.clock.nowMs - goneAt, greaterThanOrEqualTo(120 * 1000 + TableClient.quorumLostAfterMs));
    expect(c.failure, Failure.jurorQuorumLost);
    final juror = t.jurors.firstWhere((j) => j.signer.publicKey == kept).client!;
    expect(t.clock.runUntil(() => !juror.serving, limitMs: 10 * 1000), isTrue, reason: 'and the juror heard it:\n${juror.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The juror left cannot hear the people
  // when they say it. An ended side says it again to whoever is still
  // talking to it, as a side behind is carried forward.
  test('a juror cut off when the game ended: told once it is back', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final hand = c.game.handNumber;
    final drawn = c.juries.last.event.jurors;
    final held = c.botHolders(hand).values.toSet();
    final kept = drawn.firstWhere((k) => !held.contains(k));
    for (final j in drawn.where((k) => k != kept)) {
      t.net.goOffline(j);
    }
    for (final p in t.clients) {
      t.net.cut(kept, p.signer.publicKey);
    }
    final juror = t.jurors.firstWhere((j) => j.signer.publicKey == kept).client!;
    expect(t.clock.runUntil(() => t.clients.every((c) => c.failure != null), limitMs: 4 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${c.describe()}');
    final records = [for (final c in t.clients) c.record.length];
    t.clock.advance(15 * 1000);
    expect(juror.serving, isTrue, reason: 'it has heard nothing yet');
    for (final p in t.clients) {
      t.net.uncut(kept, p.signer.publicKey);
    }
    expect(t.clock.runUntil(() => !juror.serving, limitMs: 30 * 1000), isTrue,
        reason: 'told once back, not five minutes on:\n${juror.describe()}');
    expect(juror.failure, Failure.jurorQuorumLost);
    expect([for (final c in t.clients) c.record.length], records, reason: 'nothing new in the record');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A table of four people has no bot seats, so its hands are sealed to
  // no draw — and still escrowed to the jury, whose pieces with a
  // person's open a leaver's hand. Read from the draw a hand was sealed
  // to, the table counted nobody holding such a piece, took the
  // leaver's seat for one nobody could open, and ended the game twenty
  // seconds in, with the jury there and its pieces on their way. The
  // custodians a seat's keys named are who holds them.
  test('a leaver\'s hand at a table of four people, the jury slow with its pieces: the game waits, and goes on', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing && c.game.tricksPlayed >= 1, limitMs: 5 * 60 * 1000), isTrue);
    expect(c.sealedTo(c.game.handNumber), isNull, reason: 'no bot seats, so no draw holds any');
    final jurors = {for (final j in t.jurors) j.signer.publicKey};
    final until = t.clock.nowMs + 45 * 1000;
    t.net.steer = (from, to, message) => message['kind'] == 'release' && jurors.contains(from) && t.clock.nowMs < until ? -1 : null;
    final hand = c.game.handNumber;
    t.clients.last.leave();
    expect(t.clock.runUntil(() => c.pause == Pause.openingHand, limitMs: 60 * 1000), isTrue, reason: 'stopped at the leaver\'s seat');
    final seat = c.stalled.values.first;
    expect(c.pieceHoldersOf(hand, seat), isNotEmpty, reason: 'the jury holds pieces of the leaver\'s hand');
    expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the hand was played out once the pieces came:\n${c.describe()}');
    for (final x in t.clients.take(3)) {
      expect(x.failure, isNull, reason: x.describe());
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
