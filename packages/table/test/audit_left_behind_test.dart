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
    // next turn; then back, playing the rest of the hand as its juror.
    t.net.doze(holderKey);
    expect(t.clock.runUntil(() => a.deal?.gone.contains(seat) ?? false, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the people gave the seat to the escrow');
    t.net.wake(holderKey);

    expect(t.clock.runUntil(() => a.game.handNumber > hand && a.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the table dealt the next hand:\n${a.describe()}');
    expect(t.clock.runUntil(() => (holder.client?.game.handNumber ?? 0) > hand, limitMs: 60 * 1000), isTrue,
        reason: 'and the juror came with it:\n${holder.client?.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And the players among themselves. Given up to the escrow is each
  // side's own judgement: a juror's move that reaches one person in
  // time and the other late has the seat given up at one and not the
  // other, and the table goes on — the move is the same either way
  // (two_voices_test.dart). Not the audit. The side that gave the seat
  // up settled it from the escrow's pieces, with nothing said; the
  // other waited for everyone to witness the juror's own audit, which
  // the first never did. The table stopped there for good, or finished
  // holding two records (explorer, topup scenario).
  test('a seat one person gave to the escrow and the other did not: its juror\'s own audit settles it on both records', () {
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
    // The juror's moves, kept from everyone but b for four seconds: a
    // and the jury give the seat up at three, and b has the move.
    final until = t.clock.nowMs + 4000;
    t.net.steer = (from, to, message) =>
        from == holder && to != b.signer.publicKey && message['kind'] == 'play' && t.clock.nowMs < until ? -1 : null;
    expect(t.clock.runUntil(() => a.deal!.gone.contains(seat), limitMs: 10 * 1000), isTrue, reason: 'a gave the seat up');
    t.clock.advance(5000);
    expect(b.deal!.gone.contains(seat), isFalse, reason: 'b did not');

    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out, audits and all:\n${a.describe()}${b.describe()}');
    expect(a.record.map((d) => d.key).toList(), b.record.map((d) => d.key).toList(), reason: 'one record');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
