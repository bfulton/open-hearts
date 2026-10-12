/// A person leaving while a hand is being dealt, heard late by two
/// jurors.
///
/// Which juror holds which bot seat is `assignBots(jury, the bot
/// seats)`, and it hands them out in order — so a peer that counts
/// one bot seat more than another puts every juror on a different
/// seat, and each then refuses what the others say for theirs. A
/// person leaving turns their seat into a bot, so a leave still in
/// flight is exactly that disagreement, and the hand would stop at a
/// seat whose keys are nobody's to make.
///
/// The seat list is read from the record, by the hand a removal was
/// placed in, so hearing the leave late does not change it.
library;

import 'package:deal/deal.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a leave heard late by two jurors does not move the bot seats under them', () {
    final t = SimTable(humans: 3, seed: 12, crypto: crypto, jurors: jurySize);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    // Into the second hand, so the leave lands while a deal is being
    // built rather than before the table has one.
    final dealt = t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 10 * 60 * 1000);
    expect(dealt, isTrue, reason: 'the table reached hand 1: ${t.clients.first.describe()}');
    final hand = t.clients.first.game.handNumber;

    // Two jurors cut off from the leaver, so they hear of the leave
    // only when somebody else carries it — which is the ordinary way
    // round, and a second or two later than everyone else.
    final leaver = t.people[2];
    final behind = t.jurors.where((j) => j.client != null).take(2).toList();
    expect(behind.length, 2, reason: 'two jurors were following the table');
    for (final j in behind) {
      t.net.cut(leaver.client.signer.publicKey, j.signer.publicKey);
    }
    leaver.depart(Exit.leave);
    t.clock.advance(3000);
    t.net.heal();

    // Every side names the same juror for every bot seat of the hand.
    // Without this being a fact of the record, the two behind named
    // their own.
    final views = <String, Map<int, PublicKey>>{
      for (final c in t.survivors) c.signer.publicKey.substring(0, 4): c.botHolders(hand),
      for (final j in t.jurors)
        if (j.client != null) j.signer.publicKey.substring(0, 4): j.client!.botHolders(hand),
    };
    final first = views.values.first;
    for (final e in views.entries) {
      expect(e.value, first,
          reason: 'every side reads the same bot seats for hand $hand:\n'
              '${views.entries.map((v) => '${v.key}: ${v.value.map((s, k) => MapEntry(s, k.substring(0, 4)))}').join('\n')}');
    }
    // And the hand goes on: the seat the person left is played out
    // from its escrow, and the seats the jury holds are dealt.
    final on = t.clock.runUntil(() => t.clients.first.game.handNumber > hand, limitMs: 10 * 60 * 1000);
    expect(on, isTrue, reason: 'the hand was played to its end: ${t.clients.first.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
