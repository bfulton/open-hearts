/// A deal step that arrives before the jury that vouches for it.
///
/// A bot seat's keys name the custodians they were sealed to, and a
/// peer refuses them until it has seen all of those keys proposed as
/// jurors (client.dart, `_validDeal`). A juror hears a hand's jury a
/// moment after the table does, so the keys and the jury it is
/// checked against arrive in either order — and in the seeded hand
/// below they arrive twenty milliseconds the wrong way round.
///
/// Refusing them is right. Throwing them away was not: from there the
/// only way back was for somebody to say them again, and a carry
/// holds an event back for eight seconds after the last copy of it
/// went out (`carryRepeatMs`). Fourteen seeded hands in twenty lost
/// nine seconds of their deal to exactly that.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  // Seed 1 is one of the hands where the order goes the wrong way; it
  // dealt in 15.4 s while the ones that got it the right way round
  // dealt in 6.6 s (tool/time_to_deal.dart). Ten seconds is well
  // clear of both.
  test('a deal step refused for arriving before its jury is kept, not thrown away', () {
    final t = SimTable(humans: 2, seed: 1, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final dealt = t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 10000);
    expect(dealt, isTrue,
        reason: 'the hand was dealt inside ten seconds, so nothing waited on a copy of what it already held:\n'
            '${t.clients.first.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
