/// A witness to the jury, lost on its way to the one who proposed it.
///
/// At a table of two, the one copy of the first person's witness to
/// the second's jury proposal is lost (as `tool/explore.dart` does, one
/// copy of one message at a time). The proposer says its proposal
/// again until it carries — the same event — and a peer that has
/// already backed it answers with its witness again, or the proposer
/// would wait for a jury the other is already dealing under.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a jury witness lost on its way to the proposer is said again, and the hand deals', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    final a = t.signers[0].publicKey;
    final b = t.signers[1].publicKey;
    var lost = 0;
    t.net.steer = (from, to, message) {
      if (lost > 0 || from != a || to != b || message['kind'] != 'witness') return null;
      final body = message['body'] as Map<String, Object?>?;
      if (body?['jury'] != true) return null;
      lost++;
      return -1;
    };
    t.start();
    bool pastFirstTrick(TableClient c) => c.game.phase == Phase.playing && c.game.tricksPlayed >= 1;
    final dealt = t.clock.runUntil(() => t.clients.every(pastFirstTrick), limitMs: 90 * 1000);
    expect(lost, 1, reason: 'the witness was lost');
    expect(dealt, isTrue, reason: 'both were through the first trick:\n${t.clients.map((c) => c.describe()).join('\n')}');
    for (final c in t.clients) {
      expect(c.record.where((d) => d.removal), isEmpty, reason: 'nobody was booted for it');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
