/// A bot seat whose juror goes quiet, and the hand that plays on.
///
/// A juror holds each bot seat so that nobody at the table sees its
/// hand (docs/04-live-play.md). When that juror goes, the seat is
/// nobody's: the escrow reopens it to the jury, and the seat has to go
/// on being played or the hand stops at its turn — with the rest of
/// the table holding cards it cannot play.
///
/// And reopening it must not hand the seat to the people playing.
/// What it takes to rebuild a secret is hearing [escrowThreshold]
/// pieces, not being given one, so a piece said in the clear is a
/// piece the players have too: a bot seat's go sealed to the
/// custodians for as long as the hand is being played.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a bot seat is played on after the juror holding it goes quiet, and stays shut to the table', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
    t.start();
    t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 20 * 60 * 1000);
    final client = t.clients.first;
    final hand = client.game.handNumber;
    final held = client.botHolders(hand);
    expect(held, isNotEmpty, reason: 'the jury holds the bot seats');

    // The juror holding the seat on turn goes, and it is the seat the
    // hand is waiting on: nothing moves until the escrow opens it.
    final onTurn = client.game.currentSeat;
    expect(held.containsKey(onTurn), isTrue, reason: 'seat $onTurn is a held bot seat');
    t.net.goOffline(held[onTurn]!);

    // While the hand is played, the seat opens to the jury and to
    // nobody at the table. At two people and two bots, seeing both
    // bots' hands is seeing the other person's by subtraction, which
    // is what the jury is for; the escrow may not give that away.
    //
    // Only while it is played. Once the hand is over the audit
    // publishes every secret, the pieces go in the clear with them,
    // and that is where anyone may check the hand.
    var looked = 0;
    final until = t.clock.nowMs + 5 * 60 * 1000;
    while (t.clock.nowMs < until) {
      t.clock.advance(500);
      if (client.game.handNumber != hand || client.game.phase != Phase.playing) break;
      for (final c in t.clients) {
        final d = c.dealOf(hand);
        if (d == null) continue;
        looked++;
        expect(d.knowsSecret(onTurn!), isFalse,
            reason: 'seat $onTurn stayed shut to the player at seat ${c.mySeat} while the hand was played');
      }
    }
    expect(looked, greaterThan(0), reason: 'the players were looked at while the hand ran');

    final moved = t.clock.runUntil(() => client.game.handNumber > hand, limitMs: 5 * 60 * 1000);
    expect(moved, isTrue, reason: 'the hand finished: ${client.describe()}');
    // And a seat's holder is whoever's keys settled its first deal
    // round — a fact of the record, the same on every side that has
    // read that far, which is what says whether a seat was given up
    // or merely waited on. A juror still replaying the deal has not
    // read it yet and goes on the draw it was summoned with; that is
    // the reading the record is there to correct, and it does.
    for (final j in t.jurors) {
      final c = j.client;
      if (c == null || !t.net.isUp(j.signer.publicKey)) continue;
      final keyed = c.keyedBy(hand);
      for (final seat in held.keys) {
        if (!keyed.containsKey(seat)) continue;
        expect(c.botHolders(hand)[seat], held[seat],
            reason: 'seat $seat is held by whoever keyed it, on every side that has settled it');
      }
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
