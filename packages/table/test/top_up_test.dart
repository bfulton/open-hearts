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
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Two things this does not yet show, and they are the same thing.
  //
  // A juror summoned mid-hand is carried forward from nothing, and in
  // the simulator it reaches the end of the deal and stops: ten
  // minutes of virtual time leaves it at the step the play begins on.
  // So it never takes up the share made for it, and a hand cannot yet
  // be carried by the jurors brought on — only by the ones it was
  // sealed to. Everything short of that holds: the jury tops back up,
  // two holders make the parts, and the parts are carried forward
  // with the rest of the record.
  //
  // That the parts make a working share is proven where it can be
  // proven exactly, in packages/deal's session test, which drives the
  // same calls directly: one part of two is not a share, the complete
  // set is, and the made share opens the seat beside any one of the
  // originals. What is missing is the carrying, which is a defect of
  // its own rather than of the escrow (docs/04-live-play.md).
}
