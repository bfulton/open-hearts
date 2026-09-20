/// A bot seat whose juror goes quiet, and the hand that plays on.
///
/// A juror holds each bot seat so that nobody at the table sees its
/// hand (docs/04-live-play.md). When that juror goes, the seat is
/// nobody's: the escrow opens it, and the seat has to go on being
/// played or the hand stops at its turn — with the rest of the table
/// holding cards it cannot play.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a bot seat is played on after the juror holding it goes quiet', () {
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

    final moved = t.clock.runUntil(() => client.game.handNumber > hand, limitMs: 5 * 60 * 1000);
    expect(moved, isTrue, reason: 'the hand finished: ${client.describe()}');
    // And every peer still here agrees who held it, which is what
    // says whether the seat was given up or merely waited on.
    for (final j in t.jurors) {
      final c = j.client;
      if (c == null || !t.net.isUp(j.signer.publicKey)) continue;
      expect(c.botHolders(hand), held, reason: 'the assignment is the record\'s, not this peer\'s');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
