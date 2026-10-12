/// A bot seat's deal step, said once and lost.
///
/// A dropped message is the ordinary reason a turn does not settle,
/// and the ordinary answer is that whoever said it says it again. A
/// seat does that ([TableClient] `_repeat`), and so does a juror for
/// the bot seat it holds. Nothing else would come to the rescue: the
/// holder skips a turn that already carries its own action, the
/// carry-forward carries only what has settled somewhere, and a table
/// waiting on a deal turn is neither split nor paused, so no appeal is
/// made and no juror relays anything.
///
/// One human and three bot seats, which is what matchmaking gives
/// somebody who asks for a game alone.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

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

  // Lost on the way to one player only, and every copy after it kept
  // from that player for a while: the rest of the table settles the
  // step and goes on, and that player is behind. It hears the others
  // heartbeat from further on, and its own copy of the turn is still
  // open. The holder's deal steps are on a clock (TableTiming
  // botDealsMs), and that player timed the holder by its own
  // open turn — judged it idle, gave the seat to the escrow and the
  // hand up undealt, by itself, while the table dealt the hand without
  // it. Behind is the one place the holder cannot be timed from.
  test('a bot seat\'s keys kept from one player: it waits to be carried, and does not give the hand up alone', () {
    final t = SimTable(humans: 3, seed: 4, crypto: crypto, jurors: jurySize);
    final a = t.signers.first.publicKey;
    final seated = {for (final s in t.signers) s.publicKey};
    var kept = 0;
    // Kept until well past the deal step's allowance, so that timing
    // the holder by its own open turn would give the hand up.
    final keptFor = TableTiming.standard.botDealsMs + 15000;
    t.net.steer = (from, to, message) {
      if (to != a || message['kind'] != 'deal' || t.clock.nowMs >= keptFor) return null;
      final body = message['body'] as Map<String, Object?>?;
      if (body == null || body['round'] != 0 || seated.contains(message['author'])) return null;
      kept++;
      return -1;
    };
    t.start();
    final all = t.clients.toList();
    expect(t.clock.runUntil(() => all.every((c) => c.game.phase == Phase.playing), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'every player dealt in:\n${all.map((c) => c.describe()).join()}');
    expect(kept, greaterThan(0), reason: 'the juror\'s keys were kept from the one player');
    for (final c in all) {
      expect(c.game.handNumber, 0, reason: 'the same hand everywhere, not one given up at one side: ${c.describe()}');
    }
    expect(t.clock.runUntil(() => all.every((c) => c.game.handNumber > 0), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'and played out');
    final keys = [for (final c in all) c.record.map((d) => d.key).join(',')];
    expect(keys.toSet(), hasLength(1), reason: 'one record');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Carried at once, whatever its key. The lowest key among the live
  // players answers a player that is behind straight away and the
  // rest after a couple of heartbeats, so that one answer goes out
  // rather than three — and the asker was counted among them. Where
  // its own key was the lowest, nobody was first, and it waited out
  // the couple of heartbeats meant for the second in line.
  test('a player behind whose key is the lowest at the table is carried at once', () {
    final t = SimTable(humans: 3, seed: 4, crypto: crypto, jurors: jurySize);
    final lowest = (t.signers.map((s) => s.publicKey).toList()..sort()).first;
    final seated = {for (final s in t.signers) s.publicKey};
    TurnId? lost;
    int? lostAt;
    t.net.steer = (from, to, message) {
      if (lost != null || to != lowest || message['kind'] != 'deal') return null;
      final body = message['body'] as Map<String, Object?>?;
      if (body == null || body['round'] != 0 || seated.contains(message['author'])) return null;
      lost = TurnId.deal(body['hand'] as int, 0, body['seat'] as int);
      lostAt = t.clock.nowMs;
      return -1;
    };
    t.start();
    final behind = t.clients.firstWhere((c) => c.signer.publicKey == lowest);
    final others = t.clients.where((c) => c != behind).toList();
    expect(t.clock.runUntil(() => lost != null && others.every((c) => c.turnStates[lost!] == TurnState.settledByAction),
        limitMs: 60 * 1000), isTrue, reason: 'the step settled everywhere else');
    final settledElsewhere = t.clock.nowMs;
    expect(t.clock.runUntil(() => behind.turnStates[lost!] == TurnState.settledByAction, limitMs: 60 * 1000), isTrue,
        reason: 'and was carried to the player that lost it');
    // Within a heartbeat of the others', and so well inside the deal's
    // own clock; the couple of heartbeats of the second in line are
    // eleven seconds.
    expect(t.clock.nowMs - settledElsewhere, lessThan(t.clients.first.heartbeatMs + 2000),
        reason: 'lost at ${lostAt}ms, settled elsewhere at ${settledElsewhere}ms, here at ${t.clock.nowMs}ms');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
