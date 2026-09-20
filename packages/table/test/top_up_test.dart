/// The jury tops back up, and whoever joins is given a share.
///
/// A jury that only shrinks is the shape the sizing was stuck on: a
/// bot seat's escrow rests on enough of the jurors it was sealed to
/// still being reachable when the seat's holder goes
/// (docs/04-live-play.md, "The sizing"). Bringing somebody on is the
/// lever, and it is worth nothing unless the newcomer is given a
/// share of what the others hold.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a juror drawn after the deal is given a share, and it opens a bot seat', () {
    // More jurors online than a jury takes, so there is somebody to
    // bring on when the first lot start going.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
    t.start();
    t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 20 * 60 * 1000);
    final client = t.clients.first;
    final hand = client.game.handNumber;
    final sealedTo = client.juries.where((d) => d.event.hand == hand).map((d) => d.event.jurors.toSet()).first;
    expect(sealedTo, isNotEmpty, reason: 'a jury was drawn for the hand');

    // Two of the jury go. The table should draw replacements rather
    // than carry on with what is left.
    final leaving = sealedTo.take(2).toList();
    for (final k in leaving) {
      t.net.goOffline(k);
    }
    t.clock.advance(60000);

    final now = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet();
    final brought = now.difference(sealedTo);
    expect(brought, isNotEmpty, reason: 'the jury was topped back up: $now against $sealedTo');

    // And the holders make parts of a share for whoever was brought
    // on: two of them, for each newcomer and each bot seat.
    final sent = [
      for (final j in t.jurors)
        if (sealedTo.contains(j.signer.publicKey) && (j.client?.topUpsSent ?? 0) > 0) j.signer.publicKey,
    ];
    expect(sent.length, escrowThreshold, reason: 'two holders answer, not all of them');

    // And the newcomers take the parts up: two parts make one share,
    // and a juror brought on mid-hand holds a piece of the escrow it
    // was never sealed to. This is what the topping up is for — the
    // jury that carries the rest of the hand is the one standing at
    // the end of it, not the one the deal went out to.
    final carried = t.clock.runUntil(() => client.game.handNumber > hand, limitMs: 5 * 60 * 1000);
    expect(carried, isTrue, reason: 'the hand played on: ${client.describe()}');
    // The table does not wait for them: a juror brought on judges the
    // silence of the one it replaced from where it came in, so it
    // reaches the end of the hand a little after the table does.
    final ours = [for (final j in t.jurors) if (brought.contains(j.signer.publicKey)) j];
    final caught = t.clock.runUntil(
      () => ours.every((j) => (j.client?.game.handNumber ?? -1) > hand),
      limitMs: 5 * 60 * 1000,
    );
    expect(caught, isTrue,
        reason: 'every juror brought on carried the hand to its end:\n'
            '${[for (final j in ours) j.client?.describe()].join('\n')}');
    for (final j in ours) {
      expect(j.client?.holdsEscrowPiece(hand), isTrue,
          reason: '${j.signer.publicKey.substring(0, 4)}, brought on at hand $hand, holds a piece of it');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
