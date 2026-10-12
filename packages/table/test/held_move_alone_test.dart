/// A held bot seat's move, with the only other person gone silent.
///
/// At a sealed table of two people and two bots, the jury holds the
/// bot seats. When one person goes quiet, a held seat's move has the
/// survivor's voice and nobody else's: one of the two it needs. The
/// survivor appeals, and the jury rules as it does for a person's seat
/// — the holder heard and moved, the move stands — or the hand would
/// stop at the seat for good.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('the other person goes silent as a held seat is to move: the jury carries the move, and the hand goes on', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final client = t.clients.first;
    final quiet = t.people[1].client.signer.publicKey;
    // The first held seat's turn of the play.
    final reached = t.clock.runUntil(() {
      final g = client.game;
      return g.phase == Phase.playing && client.botHolders(g.handNumber).containsKey(g.currentSeat);
    }, limitMs: 20 * 60 * 1000);
    expect(reached, isTrue, reason: client.describe());
    final hand = client.game.handNumber;
    final turn = client.step;
    // Gone before it can back the move.
    t.net.goOffline(quiet);
    t.people[1].stop();

    final moved = t.clock.runUntil(() => client.step > turn || client.game.handNumber > hand, limitMs: 5 * 60 * 1000);
    expect(moved, isTrue, reason: 'the held seat\'s move was carried: ${client.describe()}');
    final carried = client.record.lastWhere((d) => !d.removal && client.holders[d.event.seat] is BotSeat);
    expect(carried.verdict, isNotNull, reason: 'by the jury, the survivor\'s voice being one of two');

    final v = verifyRecord(t.spec, client.record, juries: client.juries, crypto: crypto, releases: client.releases, allowPartial: true);
    expect(v.ok, isTrue, reason: v.reason);
    t.stop();
  });
}
