/// Sealed tables with a seat that lies about its deal: a card it says
/// it does not hold, a pass sealed to nobody. The rest of the sealed
/// table's tests are in sealed_test.dart.
@Tags(['slow'])
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

import 'sealed.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  /// A table where every seat says it holds the two of clubs nowhere.
  /// Three of them are telling the truth; whichever was dealt the card
  /// is not, and nothing in the deal's proofs can tell them apart
  /// (docs/explanation/fair-deal.md) — there is nothing to prove about a card
  /// you say you do not hold. [how] is which kind of modified client
  /// they are. The lie lasts one hand: the seat that told it is out
  /// before another is dealt, and the rest play on honestly.
  SimTable liarsTable(Lie how, {int seed = 11}) {
    final t = SimTable(humans: 4, seed: seed, crypto: crypto, jurors: juryToHoldBots);
    for (final c in t.clients) {
      c.lies = how;
      c.changes.listen((_) {
        if (c.game.handNumber > 0) c.lies = null;
      });
    }
    return t;
  }

  /// Hand 0 was given up, unplayed and unscored, and its deal was
  /// opened to say why.
  void gaveUpTheFirstHand(Iterable<TableClient> among) {
    for (final c in among) {
      expect(c.lastHand, isNull, reason: 'a hand nobody could lead has no score sheet');
      final hand0 = c.record.where((d) => d.turn.hand == 0).toList();
      expect(hand0.where((d) => d.turn.isPass || d.turn.isPlay), isEmpty,
          reason: 'not a card was passed or played in it');
      expect(hand0.where((d) => d.turn.isAudit).length, 4, reason: 'and every seat of it was opened');
    }
  }

  test('a seat that disclaims the two of clubs and plays on regardless is booted at the audit it will not answer', () {
    final t = liarsTable(Lie.declare);
    t.start();
    // Three of the four stop before the hand begins; the fourth dealt
    // itself a hand only it can play, which is how it gives itself away.
    expect(t.clock.runUntil(() => t.clients.where((c) => c.pause == Pause.waitingForLead).length == 3, limitMs: 60000), isTrue,
        reason: 'nobody the table can hear claims the lead card');
    final liar = t.clients.firstWhere((c) => c.pause == null);
    // Settling is not simultaneous: the three stop at the lead, and the
    // liar is still finishing the deal it gave itself. Wait for it to
    // get its hand rather than sample the instant the others stopped.
    expect(t.clock.runUntil(() => liar.game.phase == Phase.passing, limitMs: 60000), isTrue,
        reason: 'the modified client alone got a hand out of it');
    final honest = t.clients.where((c) => c != liar).toList();

    // It never answers the audit the others called, and its heartbeats
    // put it behind them for ever — which is not catching up, it is a
    // client that took a path of its own. The clock has it.
    expect(t.clock.runUntil(() => honest.every((c) => c.holders[liar.mySeat!] is BotSeat), limitMs: 200000), isTrue,
        reason: 'the seat is booted at the turn it will not answer');
    expect(t.clock.runUntil(() => honest.every((c) => c.game.handNumber > 0), limitMs: 60000), isTrue,
        reason: 'and the hand nobody could lead is given up for one they can');
    gaveUpTheFirstHand(honest);

    expect(t.clock.runUntil(() => honest.every((c) => c.done), limitMs: 3 * 60 * 60 * 1000), isTrue,
        reason: 'the other three finish the game');
    // The one that was removed never took in its own removal: it is at
    // the hand it dealt itself, holding a record the table left behind.
    expect(liar.game.handNumber, 0);
    agreeAmong(t, honest);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a seat that disclaims the two of clubs and waits with the rest is caught by the deal it helped open', () {
    final t = liarsTable(Lie.hide);
    t.start();
    // Nothing this one does is out of step: it stops when the table
    // stops and audits when the table audits. What it cannot do is not
    // have been dealt the card.
    expect(t.clock.runUntil(() => t.clients.every((c) => c.pause == Pause.waitingForLead), limitMs: 60000), isTrue,
        reason: 'the whole table stops before the hand begins');
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.handNumber > 0), limitMs: 120000), isTrue,
        reason: 'the hand is opened, given up, and the next one dealt');
    gaveUpTheFirstHand(t.clients);
    for (final c in t.clients) {
      expect(c.pause, isNull, reason: 'and the table is moving again');
    }

    // And the seat the open deal names is out, at the first turn of its
    // own that opened: not the turn it lied at, which settled long
    // before the cards said so.
    expect(t.clock.runUntil(() => t.survivors.length == 3, limitMs: 120000), isTrue, reason: 'the liar is removed');
    final out = t.clients.firstWhere((c) => !c.amSeated);
    expect(out.game.handNumber, 1, reason: 'removed in the hand after the one it spoiled');
    expect(t.run(), isTrue, reason: 'the other three finish the game');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a pass sealed to nothing gets no further than its own turn, and the clock has the seat', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto, jurors: juryToHoldBots);
    final sealer = t.clients.first;
    sealer.lies = Lie.seal;
    sealer.changes.listen((_) {
      if (sealer.game.handNumber > 0) sealer.lies = null;
    });
    final into = (0 + PassDirection.forHand(0).seatOffset) % seatCount;
    final receiver = t.clients.firstWhere((c) => c.mySeat == into);
    // Not t.survivors: that is every client that still believes it is
    // seated, and this one's record parts from the table's at the pass
    // it spoiled, so whether it ever takes in its own removal is the
    // deal's business. The three that did not lie are the table.
    final honest = t.clients.where((c) => c != sealer).toList();
    t.start();

    // Sealing three cards to nothing is caught by every seat, not only
    // the receiver: every seat checks the argument beside a seal
    // (docs/explanation/fair-deal.md), so the pass is refused where it
    // is made — the seat is left at its own turn with nothing settled,
    // and the clock takes it there.
    expect(t.clock.runUntil(() => t.clients.skip(1).every((c) => c.holders[0] is BotSeat), limitMs: 300000), isTrue,
        reason: 'the pass never carries, and the seat goes at the turn it was made at');
    expect(receiver.amSeated, isTrue, reason: 'and the seat it was aimed at is untouched');
    expect(t.clock.runUntil(() => honest.every((c) => c.game.handNumber > 0 || c.game.phase == Phase.playing), limitMs: 120000),
        isTrue,
        reason: 'the hand is played, not given up: the escrow opens what the seal did not');

    expect(t.clock.runUntil(() => honest.every((c) => c.done), limitMs: 3 * 60 * 60 * 1000), isTrue,
        reason: 'the other three finish the game');
    agreeAmong(t, honest);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
