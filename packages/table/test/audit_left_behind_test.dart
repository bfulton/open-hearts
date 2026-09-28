/// A juror whose seat went to the escrow, left behind at that seat's
/// audit.
///
/// The table settles a given-up seat's audit with nothing said: the
/// seat's secret is out in the clear at the hand's end, and every side
/// checks the hand for itself. The seat's juror, only late rather than
/// gone, never judged its own seat given up; it said the seat's audit
/// and waited for the others to witness it. They had settled that turn
/// already and never would, and carrying the juror forward carries
/// what was decided — which, for a turn settled with nothing said, is
/// nothing. So the juror stayed at that audit while the table dealt the
/// next hand without it, and in a later hand whose draw gave it a seat,
/// the table sat waiting for that seat's keys with every juror
/// heartbeating (sealed chaos seed 5).
///
/// With the escrow on the record the same juror was stuck a step
/// earlier, at the turn itself. Its card, said while it slept, went
/// out when it woke and reached the people after the escrow, where a
/// juror's move is as good as a custodian's, and they carried it. The
/// juror had let the card go when the escrow reopened the turn, and
/// every copy after that — its own, and the people's witnesses — was
/// one it had already seen.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a juror whose seat the table gave to the escrow follows the table past that seat\'s audit', () {
    // Two hands at least: nobody reaches 27 in one.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 27);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    final a = t.clients.first;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final seat = a.botHolders(hand).keys.first;
    final holderKey = a.botHolders(hand)[seat]!;
    final holder = t.jurors.firstWhere((j) => j.signer.publicKey == holderKey);
    // Asleep long enough for the people to give its seat up at its
    // next turn; then back, following the rest of the hand.
    t.net.doze(holderKey);
    expect(t.clock.runUntil(() => a.deal?.gone.contains(seat) ?? false, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the people gave the seat to the escrow');
    t.net.wake(holderKey);

    expect(t.clock.runUntil(() => a.game.handNumber > hand && a.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the table dealt the next hand:\n${a.describe()}');
    expect(t.clock.runUntil(() => (holder.client?.game.handNumber ?? 0) > hand, limitMs: 60 * 1000), isTrue,
        reason: 'and the juror came with it:\n${holder.client?.describe()}');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And the players among themselves. Given up to the escrow was once
  // each side's own judgement: a juror's move that reached one person
  // in time and the other late had the seat given up at one and not
  // the other, and the table went on — the move was the same either
  // way. Not the audit. The side that gave the seat up settled it from
  // the escrow's pieces, with nothing said; the other waited for
  // everyone to witness the juror's own audit, which the first never
  // did. The table stopped there for good, or finished holding two
  // records (explorer, topup scenario). Now the escrow is claimed at
  // the seat's turn and carried or not like a boot, so the same timing
  // is one race between the move and the claim, with one winner on
  // every record — and the audit follows from it.
  test('a juror\'s move one person heard in time and the other did not: the move or the escrow, the same on both records', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize, target: 1);
    t.start();
    final a = t.clients.first;
    final b = t.clients.last;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final held = a.botHolders(hand);
    expect(t.clock.runUntil(() => held.containsKey(a.game.currentSeat), limitMs: 60 * 1000), isTrue,
        reason: 'a held seat\'s turn');
    final seat = a.game.currentSeat!;
    final holder = held[seat]!;
    final turn = TurnId.play(hand, a.game.tricksPlayed * seatCount + a.game.trick.length);
    // The juror's moves, kept from everyone but b for four seconds: a
    // claims the escrow at three, and b has the move.
    final until = t.clock.nowMs + 4000;
    t.net.steer = (from, to, message) =>
        from == holder && to != b.signer.publicKey && message['kind'] == 'play' && t.clock.nowMs < until ? -1 : null;
    final claimed = <String>{};
    t.net.swallow = (from, message) {
      if (message['kind'] == 'escrow') claimed.add(from);
      return false;
    };

    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out, audits and all:\n${a.describe()}${b.describe()}');
    expect(claimed, contains(a.signer.publicKey), reason: 'a claimed the escrow');
    expect(a.record.map((d) => d.key).toList(), b.record.map((d) => d.key).toList(), reason: 'one record');
    expect(a.record.where((d) => d.turn == turn).any((d) => d.verdict != null), isTrue,
        reason: 'the move and the claim split the table, and the jury ruled');
    expect(a.escrowedAt(hand), b.escrowedAt(hand), reason: 'given to the escrow on both or neither');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
