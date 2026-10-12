/// A deal step that arrives before the jury that vouches for it.
///
/// A bot seat's keys name the custodians they were sealed to, and a
/// peer refuses them until it has seen all of those keys proposed as
/// jurors (client.dart, `_validDeal`). A juror hears a hand's jury a
/// moment after the table does, so the keys and the jury it is
/// checked against arrive in either order — and in the seeded hand
/// below they arrive twenty milliseconds the wrong way round.
///
/// Refusing them is right; throwing them away is not. From there the
/// only way back would be for somebody to say them again, and a carry
/// holds an event back for eight seconds after the last copy of it
/// went out (`carryRepeatMs`). So the step is kept and looked at again
/// when the jury lands.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  // Seed 1 is one of the hands where the order goes the wrong way. Kept
  // rather than dropped, its step deals in about 6.6 s, as the hands
  // that get the order right do (tool/time_to_deal.dart); dropped and
  // waited for, it would take 15. Ten seconds is well clear of both.
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
