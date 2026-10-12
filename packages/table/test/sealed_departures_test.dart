/// Sealed tables with people leaving mid-hand, and the jury holding
/// the pieces that open what they left behind. The rest of the sealed
/// table's tests are in sealed_test.dart.
@Tags(['slow'])
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

import 'sealed.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a person who leaves mid-hand has their hand opened from escrow, and the bot plays it out', () {
    final t = SimTable(humans: 4, seed: 8, crypto: crypto, jurors: 4);
    t.people[2].exitAt = Moment.offTurn;
    t.people[2].exit = Exit.leave;
    t.start();
    // The hand they left is in play still, and this deal was built
    // with their seat a person's: nobody holds it, so the escrow
    // opens it to the table and the bot finishes the hand in the
    // open. That opening is the one hand's only.
    int? leftAt;
    expect(t.clock.runUntil(() {
      if (!t.survivors.every((c) => c.seatStateOf(2) == SeatState.left)) return false;
      leftAt ??= t.survivors.first.game.handNumber;
      return t.survivors.every((c) => c.game.handNumber == leftAt && c.game.knowsHand(2));
    }, limitMs: 300000), isTrue, reason: 'the escrow opens the hand they left, in the hand they left it');
    expect(t.run(), isTrue);
    expect(t.people[2].gone, isTrue);
    expect(t.survivors.length, 3);
    for (final c in t.survivors) {
      expect(c.seatStateOf(2), SeatState.left);
      // From the next deal on the seat is a bot a juror holds, and a
      // bot seat is nobody at the table's to see (docs/explanation/live-play.md).
      expect(c.game.knowsHand(2), isFalse, reason: 'a jury-held bot seat is not the players\' to see');
    }
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('at a table of two, a crash on turn is settled by the jury and the hand opened with a juror\'s piece', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: 4);
    t.people[1].exitAt = Moment.onOwnTurn;
    t.people[1].exit = Exit.crash;
    t.start();
    expect(t.run(), isTrue);
    expect(t.survivors.length, 1);
    final c = t.survivors.first;
    expect(c.seatStateOf(1), isIn([SeatState.booted, SeatState.absent]));
    expect(c.pause, isNull);
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a lone person who leaves during the pass saw no bot\'s hand, and holds no pause', () {
    final t = SimTable(humans: 1, seed: 11, crypto: crypto, jurors: juryToHoldBots);
    t.people[0].exitAt = Moment.duringPass;
    t.people[0].exit = Exit.leave;
    final me = t.clients.first;
    var sawABot = false;
    me.changes.listen((_) {
      for (var s = 1; s < seatCount; s++) {
        if (me.game.knowsHand(s)) sawABot = true;
      }
    });
    t.start();
    // The bots' hands are the jury's, never dealt in the open, so the
    // one person at the table never sees one, leaving or not. And with
    // nobody left the jurors are serving nobody: they stop, and their
    // duty lets the table go (juror_duty.dart).
    expect(t.clock.runUntil(() => t.people[0].gone, limitMs: 10 * 60 * 1000), isTrue, reason: me.describe());
    expect(sawABot, isFalse);
    expect(me.pause, isNull);
    List<TableClient> jurors() => [for (final j in t.jurors) if (j.client != null) j.client!];
    expect(jurors(), isNotEmpty);
    expect(t.clock.runUntil(() => jurors().every((c) => !c.serving), limitMs: 10 * 60 * 1000), isTrue,
        reason: jurors().map((c) => c.describe()).join('\n'));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  for (final exit in [Exit.leave, Exit.crash]) {
    test('a person who ${exit == Exit.leave ? 'leaves' : 'crashes'} during the pass, after a pass into their seat, has that pass opened with their hand', () {
      // Three people: the one passing into the leaver is a person, so
      // the pass is sealed to the leaver and taken as unknown by all —
      // until the leaver's secret is rebuilt and the bot in the seat
      // needs the hand, pass included.
      final t = SimTable(humans: 3, seed: 12, crypto: crypto, jurors: 4);
      // Slower than the others, so a person's pass reaches the leaver
      // before the leaver's own; and the moment asks for a person's.
      t.people[1].thinkMs = 3000;
      t.people[1].exitAt = Moment('during the pass, after a person\'s pass into me', (c) {
        if (!c.awaitingMyPass) return false;
        final from = (c.mySeat! - c.game.passDirection.seatOffset) % seatCount;
        return c.spec.seats[from] is HumanSeat && c.game.hasPassed(from);
      });
      t.people[1].exit = exit;
      t.start();
      // The pass was sealed to a seat whose secret the escrow rebuilds:
      // the hand it lands in opens to the table, pass included, and the
      // bot plays it out there.
      int? leftAt;
      expect(t.clock.runUntil(() {
        if (!t.survivors.every((c) => c.seatStateOf(1) != SeatState.human)) return false;
        leftAt ??= t.survivors.first.game.handNumber;
        return t.survivors.every((c) => c.game.handNumber == leftAt && c.game.knowsHand(1));
      }, limitMs: 300000), isTrue, reason: 'the pass into the seat is opened with the hand it was sealed to');
      expect(t.run(), isTrue);
      expect(t.people[1].gone, isTrue, reason: 'the moment came');
      for (final c in t.survivors) {
        expect(c.game.knowsHand(1), isFalse, reason: 'the seat is a bot the jury holds by the end');
        expect(c.pause, isNull);
      }
      agree(t);
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('a person who leaves during the deal is a bot from there, and the deal goes on', () {
    final t = SimTable(humans: 3, seed: 10, crypto: crypto, jurors: 4);
    t.people[1].exitAt = Moment('during the deal', (c) => c.game.phase == Phase.dealing && c.deal!.hasKeys(1) && c.deal!.deck == null);
    t.people[1].exit = Exit.leave;
    t.start();
    expect(t.run(), isTrue);
    expect(t.people[1].gone, isTrue);
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
