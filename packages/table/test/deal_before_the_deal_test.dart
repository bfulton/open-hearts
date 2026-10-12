/// A hand's first steps, in hand before there is a hand to put them
/// in.
///
/// The four round-0 steps go out once the table has a jury, and a
/// juror learns it is one from a summons that can be slower than
/// that, so it can hold the steps before it has a deal to put them in.
/// They are kept rather than dropped, a turn that is not open yet
/// being no turn to be wrong for, and `_startDeal` drains them once
/// it has opened the hand's turns: the other drains run when a turn
/// settles, when a jury changes and when the assignment is fixed
/// again, and these steps are what this side needs to settle its
/// first turn.
///
/// The test holds the invariant — every juror follows the table —
/// with the summons slowed to open the window. The simulator also
/// recovers without that drain, by a path a browser lacks, so this
/// guards the invariant rather than reproducing the fault.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a deal step that arrives before the hand is built is taken up when it is', () {
    final t = SimTable(humans: 2, seed: 5, crypto: crypto, jurors: jurySize);
    // Far enough apart that a step said at once is still travelling
    // when the next side builds its deal.
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    // And a slow summons, which is what opens the window. The seats
    // hold their keys back for a moment after the jury settles and
    // then say them; the juror holds its own back for the same
    // moment, but counted from when it was told it is one. So the
    // gap between the two is exactly how long the summons took, and
    // a summons slower than that hold puts the hand's first four
    // steps in a juror's hands before it has a deal to put them in.
    // In the browsers they arrived four hundred and seventy
    // milliseconds early and the juror never recovered.
    t.presence!.summonsMs = 3000;
    t.start();
    final dealt = t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000);
    expect(dealt, isTrue, reason: 'the hand dealt: ${t.clients.first.describe()}');
    // Every juror followed it, rather than sitting at the first step
    // with the hand piling up behind it. Two hands, because the seat
    // a juror holds moves with the hand and a juror stuck at the
    // first is only found out when its turn comes round.
    final on = t.clock.runUntil(() => t.clients.first.game.handNumber >= 2, limitMs: 15 * 60 * 1000);
    expect(on, isTrue, reason: 'two hands were played: ${t.clients.first.describe()}');
    for (final j in t.jurors) {
      final c = j.client;
      if (c == null) continue;
      expect(c.game.handNumber, greaterThanOrEqualTo(1),
          reason: 'juror ${j.signer.publicKey.substring(0, 4)} followed the table:\n${c.describe()}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
