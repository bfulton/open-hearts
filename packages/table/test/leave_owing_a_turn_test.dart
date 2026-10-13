/// A person leaving with their backing of another seat's move still
/// in flight where they stand.
///
/// A leave is made at the next position when this side has a vote in
/// flight where it stands, so that the vote counts the same everywhere
/// (TableClient.leave). That leaves behind it whatever the leaver still
/// owes where it stands: no removal reaches back to it, at a table of
/// two people a boot of it needs the leaver's own vote, and no juror
/// rules it away while the leaver's device is still heard and the
/// leave has not carried. So the leaver says it itself: a pass at once,
/// as the bot taking the seat over would, and a step of the deal when
/// it comes due.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('at the pass: the pass is the bot\'s, the leave carries at the first play, and the hand goes on', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    final leaver = t.people[0]..thinkMs = 60000;
    final a = leaver.client, b = t.people[1].client;
    // The other person's backing reaches the leaver late, so the
    // leaver's own backing of a held seat's pass stays in flight.
    t.net.steer = (from, to, message) =>
        from == b.signer.publicKey && to == a.signer.publicKey && message['kind'] == 'witness' ? 20000 : null;
    t.start();
    bool backingInFlight() {
      final hand = a.game.handNumber;
      return a.botHolders(hand).keys.any((s) => a.backs(TurnId.pass(hand, s)) && !a.onRecord(TurnId.pass(hand, s)));
    }

    expect(t.clock.runUntil(() => a.awaitingMyPass && backingInFlight(), limitMs: 10 * 60 * 1000), isTrue, reason: a.describe());
    final hand = a.game.handNumber;
    final held = List.of(a.game.handOf(0));
    leaver.depart(Exit.leave);

    expect(t.clock.runUntil(() => b.game.handNumber > hand || b.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue,
        reason: b.describe());
    // The pass the seat owed: its own, as the bot taking it over
    // chooses it.
    expect(t.clock.runUntil(() => b.onRecord(TurnId.pass(hand, 0)) && a.onRecord(TurnId.pass(hand, 0)), limitMs: 60000), isTrue,
        reason: a.describe());
    expect(a.game.passOf(0), Bot(persona: t.spec.replacementFor(0)).choosePass(held));
    // And the leave where it was made: the first play.
    expect(t.clock.runUntil(() => b.seatStateOf(0) == SeatState.left, limitMs: 2 * 60 * 1000), isTrue, reason: b.describe());
    final left = b.record.firstWhere((d) => d.removal && d.event.seat == 0);
    expect(left.event.kind, EventKind.leave);
    expect(left.turn, TurnId.play(hand, 0));
    expect(t.clock.runUntil(() => b.done, limitMs: 20 * 60 * 1000), isTrue, reason: b.describe());
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('in the deal: the shuffle it owes is made when due, the leave carries at the tokens, and the hand goes on', () {
    // The bots first, so a held seat shuffles ahead of both people.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1, botsFirst: true);
    final leaver = t.people[0], a = leaver.client, b = t.people[1].client;
    final seat = a.mySeat!;
    // The other person's backing reaches the leaver late, so the
    // leaver's backing of the first held seat's shuffle stays in
    // flight, with its own shuffle still to come.
    t.net.steer = (from, to, message) =>
        from == b.signer.publicKey && to == a.signer.publicKey && message['kind'] == 'witness' ? 20000 : null;
    t.start();
    TurnId first() => TurnId.deal(a.game.handNumber, 1, 0);
    expect(t.clock.runUntil(() => a.backs(first()) && !a.onRecord(first()), limitMs: 10 * 60 * 1000), isTrue, reason: a.describe());
    final hand = a.game.handNumber;
    final mine = TurnId.deal(hand, 1, seat);
    expect(a.actionAt(mine), isNull, reason: 'its own shuffle is still to come');
    leaver.depart(Exit.leave);

    // Its own shuffle, said by its own device once it came due.
    expect(t.clock.runUntil(() => b.onRecord(mine), limitMs: 5 * 60 * 1000), isTrue, reason: b.describe());
    expect(b.actionAt(mine)!.author, a.signer.publicKey);
    // And the leave where it was made: the tokens, the next round.
    expect(t.clock.runUntil(() => b.seatStateOf(seat) == SeatState.left, limitMs: 2 * 60 * 1000), isTrue, reason: b.describe());
    final left = b.record.firstWhere((d) => d.removal && d.event.seat == seat);
    expect(left.event.kind, EventKind.leave);
    expect(left.turn, TurnId.deal(hand, 2, seat));
    expect(t.clock.runUntil(() => b.done, limitMs: 20 * 60 * 1000), isTrue, reason: b.describe());
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
