/// The time bank (docs/explanation/live-play.md), on the simulator: a
/// grace per decision, a bank per hand, and the seat lost the moment
/// both are spent — by the referee's clock, the same at every side.
library;

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// [seat]'s person's plays the log took in [hand], and whether the
/// clock had their seat there.
({int plays, bool booted}) handOf(TableClient c, int hand, int seat) {
  final r = c.rules.removals[seat];
  return (
    plays: c.rules.taken.where((e) => e.kind == EventKind.play && e.hand == hand && e.seat == seat && e.author == c.rules.spec!.seats[seat].keyOrNull).length,
    booted: r != null && r.exit == Exit.booted && r.hand == hand,
  );
}

extension on SeatHolder {
  PublicKey? get keyOrNull => switch (this) {
        HumanSeat(:final key) => key,
        BotSeat() => null,
      };
}

void main() {
  test('the allowance: a grace per decision, the bank on top, a fixed clock for the deal and the audit', () {
    const bank = TimeBank.standard;
    expect(bank.allowanceMs(const TurnId.play(0, 7), 45000), 51000);
    expect(bank.allowanceMs(const TurnId.play(0, 7), 0), 6000, reason: 'the grace stays when the bank is gone');
    expect(bank.allowanceMs(const TurnId.pass(0, 2), 45000), 65000);
    expect(bank.allowanceMs(const TurnId.deal(0, 1, 2), 45000), 40000);
    expect(bank.allowanceMs(const TurnId.audit(0, 2), 0), 40000);
  });

  test('fourteen seconds over every card loses the seat on the sixth', () {
    final t = SimTable(humans: 4, seed: 71);
    t.people[1].thinkMs = 14000;
    t.start();
    expect(t.run(), isTrue, reason: 'finished\n${t.people[0].client.rules.describe()}');
    final c = t.people[0].client;
    final h0 = handOf(c, 0, 1);
    expect(h0.plays, 5, reason: 'five cards at fourteen seconds spend forty of the forty-five');
    expect(h0.booted, isTrue, reason: 'and the sixth card runs out');
    expect(c.holders[1], isA<BotSeat>());
    for (final p in t.people.skip(2)) {
      expect(p.client.rules.endHash, c.rules.endHash, reason: 'one log');
    }
    t.close();
  });

  test('fifteen seconds over three cards, quick otherwise, keeps the seat', () {
    final t = SimTable(humans: 4, seed: 72);
    final slow = t.people[2];
    slow.thinkMs = 15000;
    // Hard thinking over the first three cards of every hand; the rest
    // in two seconds. Twenty-seven of the forty-five, and no more.
    slow.client.changes.listen((_) {
      if (slow.client.started) slow.thinkMs = slow.client.game.tricksPlayed < 3 ? 15000 : 2000;
    });
    t.start();
    expect(t.run(), isTrue, reason: 'finished\n${t.people[0].client.rules.describe()}');
    expect(t.people[0].client.rules.removals, isEmpty);
    expect(t.people[0].client.holders[2], isA<HumanSeat>());
    t.close();
  });

  test('the bank refills each hand: nine seconds a card all game keeps the seat, eleven loses it by the ninth', () {
    final a = SimTable(humans: 4, seed: 73);
    a.people[3].thinkMs = 9000;
    a.start();
    expect(a.run(), isTrue, reason: 'finished\n${a.people[0].client.rules.describe()}');
    expect(a.people[0].client.game.handNumber, greaterThanOrEqualTo(1), reason: 'more than one hand, so the bank was refilled');
    expect(a.people[0].client.rules.removals, isEmpty, reason: 'three seconds over, thirteen times, is thirty-nine');
    a.close();

    final b = SimTable(humans: 4, seed: 73);
    b.people[3].thinkMs = 11000;
    b.start();
    expect(b.run(), isTrue, reason: 'finished\n${b.people[0].client.rules.describe()}');
    final h0 = handOf(b.people[0].client, 0, 3);
    // Five seconds over, eight times, is forty: the ninth card has five
    // of bank and six of grace, and takes eleven.
    expect(h0.plays, 8);
    expect(h0.booted, isTrue);
    b.close();
  });

  test('the pass has twenty seconds free; what it takes beyond that comes off the bank', () {
    for (final (passMs, spentMs) in [(18000, 0), (30000, 10000)]) {
      final t = SimTable(humans: 4, seed: 74);
      final p = t.people[1];
      p.thinkMs = passMs;
      p.client.changes.listen((_) {
        if (p.client.started && p.client.game.phase == Phase.playing) p.thinkMs = 1000;
      });
      t.start();
      final c = t.people[0].client;
      expect(t.clock.runUntil(() => c.started && c.rules.taken.any((e) => e.kind == EventKind.pass && e.seat == 1), limitMs: 120000), isTrue);
      expect(c.rules.banks[1], inInclusiveRange(45000 - spentMs - 600, 45000 - spentMs), reason: 'a $passMs ms pass');
      expect(t.run(), isTrue);
      expect(c.rules.removals, isEmpty);
      t.close();
    }
  });

  test('the clock shows once the grace is spent, and counts the bank down', () {
    final t = SimTable(humans: 4, seed: 75);
    final p = t.people[2];
    p.client.changes.listen((_) {
      if (p.client.started) p.thinkMs = p.client.game.phase == Phase.passing ? 1000 : 30000;
    });
    t.start();
    final c = t.people[0].client;
    // Up to seat 2's first card, as seat 0 sees it.
    expect(t.clock.runUntil(() => c.started && c.rules.owed[2]?.turn.isPlay == true, limitMs: 60000), isTrue);
    final opened = t.clock.nowMs;
    expect(c.clockMs(2), isNull, reason: 'nothing to show within the grace');
    t.clock.advanceTo(opened + 3000);
    expect(c.clockMs(2), isNull);
    t.clock.advanceTo(opened + 8000);
    expect(c.clockMs(2), inInclusiveRange(42000, 43300), reason: 'two seconds into the bank');
    t.clock.advanceTo(opened + 20000);
    expect(c.clockMs(2), inInclusiveRange(30000, 31300));
    // The card comes at thirty: twenty-four off the bank.
    expect(t.clock.runUntil(() => c.rules.taken.any((e) => e.kind == EventKind.play && e.seat == 2), limitMs: 20000), isTrue);
    expect(c.clockMs(2), isNull);
    expect(c.rules.banks[2], inInclusiveRange(20000, 21000));
    t.close();
  });
}
