/// The time bank (docs/explanation/live-play.md), on the simulator: a
/// grace per decision, a bank per hand, and Boot the moment both are
/// spent — by the others' own accounting of what they saw.
library;

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// [seat]'s plays that carried in [hand], and whether it was removed there.
({int plays, bool booted}) handOf(TableClient c, int hand, int seat) => (
      plays: c.record.where((d) => d.turn.hand == hand && d.turn.isPlay && d.event.seat == seat && !d.removal).length,
      booted: c.record.any((d) => d.turn.hand == hand && d.removal && d.event.seat == seat),
    );

void main() {
  test('the allowance: a grace per decision, the bank on top, a fixed clock for the deal and the audit', () {
    const bank = TimeBank.standard;
    expect(bank.allowanceMs(const TurnId.play(0, 7), 45000), 51000);
    expect(bank.allowanceMs(const TurnId.play(0, 7), 0), 6000, reason: 'the grace stays when the bank is gone');
    expect(bank.allowanceMs(const TurnId.pass(0, 2), 45000), 65000);
    expect(bank.allowanceMs(const TurnId.deal(0, 1, 2), 45000), 40000);
    expect(bank.allowanceMs(const TurnId.audit(0, 2), 0), 40000);
  });

  test('fourteen seconds over every card is booted on the sixth', () {
    final t = SimTable(humans: 4, seed: 71);
    t.people[1].thinkMs = 14000;
    t.start();
    expect(t.run(), isTrue, reason: 'finished\n${t.people[0].client.describe()}');
    final c = t.people[0].client;
    final h0 = handOf(c, 0, 1);
    expect(h0.plays, 5, reason: 'five cards at fourteen seconds spend forty of the forty-five');
    expect(h0.booted, isTrue, reason: 'and the sixth card is the boot');
    expect(c.holders[1], isA<BotSeat>());
    for (final p in t.people.skip(2)) {
      expect(p.client.record.map((d) => d.key), c.record.map((d) => d.key), reason: 'one record');
    }
    t.stop();
  });

  test('fifteen seconds over three cards, quick otherwise, is never bothered', () {
    final t = SimTable(humans: 4, seed: 72);
    final slow = t.people[2];
    slow.thinkMs = 15000;
    // Hard thinking over the first three cards of every hand; the rest
    // in two seconds. Twenty-seven of the forty-five, and no more.
    slow.client.changes.listen((_) => slow.thinkMs = slow.client.game.tricksPlayed < 3 ? 15000 : 2000);
    var bootShown = false;
    for (final p in t.people) {
      if (p == slow) continue;
      p.client.changes.listen((_) => bootShown |= p.client.canBoot(2));
    }
    t.start();
    expect(t.run(), isTrue, reason: 'finished\n${t.people[0].client.describe()}');
    expect(bootShown, isFalse, reason: 'Boot never showed against them');
    expect(t.people[0].client.record.any((d) => d.removal), isFalse);
    expect(t.people[0].client.holders[2], isA<HumanSeat>());
    t.stop();
  });

  test('the bank refills each hand: nine seconds a card all game is never booted, eleven is by the tenth', () {
    final a = SimTable(humans: 4, seed: 73);
    a.people[3].thinkMs = 9000;
    a.start();
    expect(a.run(), isTrue, reason: 'finished\n${a.people[0].client.describe()}');
    expect(a.people[0].client.game.handNumber, greaterThanOrEqualTo(1), reason: 'more than one hand, so the bank was refilled');
    expect(a.people[0].client.record.any((d) => d.removal), isFalse, reason: 'three seconds over, thirteen times, is thirty-nine');
    a.stop();

    final b = SimTable(humans: 4, seed: 73);
    b.people[3].thinkMs = 11000;
    b.start();
    expect(b.run(), isTrue, reason: 'finished\n${b.people[0].client.describe()}');
    final h0 = handOf(b.people[0].client, 0, 3);
    // Five seconds over, eight times, is forty: bootable on the ninth
    // card with a second to spare, and the others press within a
    // second or two of the button — so by the tenth at the latest.
    expect(h0.plays, inInclusiveRange(8, 9));
    expect(h0.booted, isTrue);
    b.stop();
  });

  test('the pass has twenty seconds free; what it takes beyond that comes off the bank', () {
    for (final (passMs, spentMs) in [(18000, 0), (30000, 10000)]) {
      final t = SimTable(humans: 4, seed: 74);
      final p = t.people[1];
      p.thinkMs = passMs;
      p.client.changes.listen((_) {
        if (p.client.game.phase == Phase.playing) p.thinkMs = 1000;
      });
      t.start();
      final c = t.people[0].client;
      expect(t.clock.runUntil(() => c.record.any((d) => d.turn.isPass && d.event.seat == 1), limitMs: 120000), isTrue);
      expect(c.bankLeftMs(1), inInclusiveRange(45000 - spentMs - 600, 45000 - spentMs), reason: 'a $passMs ms pass');
      expect(t.run(), isTrue);
      expect(c.record.any((d) => d.removal), isFalse);
      t.stop();
    }
  });

  test('the clock shows once the grace is spent, and counts the bank down', () {
    final t = SimTable(humans: 4, seed: 75);
    final p = t.people[2];
    p.client.changes.listen((_) => p.thinkMs = p.client.game.phase == Phase.passing ? 1000 : 30000);
    t.start();
    final c = t.people[0].client;
    // Up to seat 2's first card.
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing && c.game.currentSeat == 2, limitMs: 60000), isTrue);
    final opened = t.clock.nowMs;
    expect(c.clockMs(2), isNull, reason: 'nothing to show within the grace');
    t.clock.runUntil(() => t.clock.nowMs >= opened + 3000, limitMs: 10000);
    expect(c.clockMs(2), isNull);
    expect(c.canBoot(2), isFalse);
    t.clock.runUntil(() => t.clock.nowMs >= opened + 8000, limitMs: 10000);
    expect(c.clockMs(2), inInclusiveRange(42000, 43300), reason: 'two seconds into the bank');
    t.clock.runUntil(() => t.clock.nowMs >= opened + 20000, limitMs: 20000);
    expect(c.clockMs(2), inInclusiveRange(30000, 31300));
    expect(c.bootCountdownMs(2), c.clockMs(2));
    expect(c.canBoot(2), isFalse);
    // The card comes at thirty: twenty-four off the bank.
    expect(t.clock.runUntil(() => c.record.any((d) => d.turn.isPlay && d.event.seat == 2), limitMs: 20000), isTrue);
    expect(c.clockMs(2), isNull);
    expect(c.bankLeftMs(2), inInclusiveRange(20000, 21000));
    t.stop();
  });
}
