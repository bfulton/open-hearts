/// A bot seat's deal step, said once and lost.
///
/// A dropped message is the ordinary reason a turn does not settle,
/// and the ordinary answer is that whoever said it says it again. A
/// seat has always done that ([TableClient] `_repeat`). A bot seat's
/// holder is a juror, and a juror did not: the step it said went
/// missing and the hand stopped at that turn for good — every peer
/// heartbeating, nobody at fault, and no path back to it. Nothing
/// else would have come to the rescue either: the holder skips a turn
/// that already carries its own action, the carry-forward carries
/// only what has settled somewhere, and a table waiting on a deal
/// turn is neither split nor paused, so no appeal is made and no
/// juror relays anything.
///
/// One human and three bot seats, which is what matchmaking gives
/// somebody who asks for a game alone, and the shape the browser
/// suite stalls on.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a bot seat\'s keys lost on the way out are said again, and the hand deals', () {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, jurors: jurySize);
    // A relay's latency, so that the step is in flight long enough
    // for the loss to be the thing that matters rather than the race.
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    // The first round-0 keys a juror says for the seat it holds, eaten
    // where they are said. Everything else goes through.
    var eaten = 0;
    final seated = {for (final s in t.signers) s.publicKey};
    t.net.swallow = (from, message) {
      if (eaten > 0 || message['kind'] != 'deal' || seated.contains(from)) return false;
      final body = message['body'] as Map<String, Object?>?;
      if (body == null || body['round'] != 0) return false;
      eaten++;
      return true;
    };
    t.start();
    final dealt = t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000);
    expect(eaten, 1, reason: 'a bot seat\'s keys were eaten on the way out');
    expect(dealt, isTrue, reason: 'the hand dealt anyway: ${t.clients.first.describe()}');
    // And it is the same hand, not one given up and dealt again: a
    // step said again costs a moment, and giving the hand up costs
    // the hand.
    expect(t.clients.first.game.handNumber, 0, reason: 'hand 0 was not abandoned: ${t.clients.first.describe()}');
    final done = t.clock.runUntil(() => t.clients.first.game.handNumber > 0, limitMs: 10 * 60 * 1000);
    expect(done, isTrue, reason: 'and played out: ${t.clients.first.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
