/// A juror whose seat went to the escrow, left behind at that seat's
/// audit.
///
/// The table settles a given-up seat's audit with nothing said: the
/// seat's secret is out in the clear at the hand's end, and every side
/// checks the hand for itself. A seat's juror that was only late
/// rather than gone has to learn from the record that its seat was
/// given up: one that says the seat's audit waits for witnesses that
/// never come, since carrying it forward carries what was decided —
/// for a turn settled with nothing said, nothing — and the table then
/// waits on it for the keys of a seat it holds in a later hand.
///
/// The same holds a step earlier, at the turn itself: the juror's card,
/// said while it slept, reaches the people after the escrow, where a
/// juror's move is as good as a custodian's, and they carry it. The
/// juror has to take it up too, although every copy of it is one it
/// has already seen.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

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

  // And the players among themselves: a juror's move that reaches one
  // person in time and the other late. The escrow is claimed at the
  // seat's turn and carried or not like a boot, so the timing is one
  // race between the move and the claim, with one winner on every
  // record — and the audit, settled from the escrow's pieces or by the
  // juror's own word, follows from it.
  test('a juror\'s move one person heard in time and the other did not: the move or the escrow, the same on both records', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize, target: 1);
    final a = t.clients.first;
    final b = t.clients.last;
    // The first held seat's juror's moves, kept from everyone but b
    // until a second past a card's allowance from its first card: a
    // claims the escrow as the allowance runs out, and b has the
    // move. Set from the start, and found by that card: a juror can
    // play a moment before a person has the turn open, and a steer
    // set once a person does was too late for it.
    final jurors = {for (final j in t.jurors) j.signer.publicKey};
    PublicKey? holder;
    TurnId? turn;
    var until = 0;
    t.net.steer = (from, to, message) {
      if (message['kind'] != 'play' || !jurors.contains(from)) return null;
      if (holder == null) {
        final body = message['body'] as Map<String, Object?>;
        holder = from;
        turn = TurnId(body['hand'] as int, body['turn'] as int);
        until = t.clock.nowMs + TableTiming.standard.botActsMs + 1000;
      }
      return from == holder && to != b.signer.publicKey && t.clock.nowMs < until ? -1 : null;
    };
    t.start();
    expect(t.clock.runUntil(() => turn != null, limitMs: 5 * 60 * 1000), isTrue, reason: 'a held seat played');
    final hand = turn!.hand;
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
