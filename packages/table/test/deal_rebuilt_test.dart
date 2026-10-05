/// A deal built again, with the steps already settled put back before
/// anything else is taken.
///
/// A juror brought on mid-hand reads the hand's redraw before the draw
/// the deal was sealed to, fixes the bot seats from the wrong one, and
/// builds its deal again when the right one comes (_refixHolders in
/// client.dart). The settled steps go back in before whatever was held
/// back for the deal: the other way round, one held-back seat's keys
/// would go into a session that has none of the others', the round of
/// keys would close with the deal still at its keys, and nothing would
/// ask the deal to go on again.
///
/// A run of `tool/explore.dart` (topup scenario, with one witness's
/// first copy lost), pinned here.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a juror topped up mid-hand, its deal built again, goes on past the keys', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    final a = t.clients.first;
    // Two jurors holding no seat go quiet during the deal, and the jury
    // is topped up while the hand is played.
    t.clock.schedule(2500, () {
      final drawn = a.juries.isEmpty ? const <PublicKey>[] : a.juries.first.event.jurors;
      final held = a.botHolders(a.game.handNumber).values.toSet();
      for (final k in drawn.where((k) => !held.contains(k)).take(2)) {
        t.net.goOffline(k);
      }
    });
    // And one copy lost: a's witness to the play at turn 20 of hand 0,
    // on its way to seat 2's juror.
    var lost = false;
    t.net.steer = (from, to, message) {
      if (lost || message['kind'] != 'witness' || from != a.signer.publicKey) return null;
      final body = message['body'] as Map<String, Object?>;
      if (body['hand'] != 0 || body['turn'] != 20 || body['seat'] != 1) return null;
      if (to != a.botHolders(0)[2]) return null;
      lost = true;
      return -1;
    };
    t.start();
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the game was played out:\n${t.clients.map((c) => c.describe()).join('\n')}');
    expect(lost, isTrue, reason: 'the copy was there to lose');
    final first = a.juries.firstWhere((d) => d.event.hand == 0).event.jurors.toSet();
    final topped = [
      for (final j in t.jurors)
        if (j.client != null && t.net.isUp(j.signer.publicKey) && !first.contains(j.signer.publicKey)) j.client!,
    ];
    expect(topped, isNotEmpty, reason: 'jurors were brought on mid-hand');
    for (final c in topped) {
      expect(c.game.phase == Phase.dealing && c.game.handNumber == 0, isFalse,
          reason: 'past the deal of hand 0:\n${c.describe()}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
