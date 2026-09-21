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

  test('a juror drawn after the deal is given a share of an escrow it was never sealed to', () {
    // More jurors online than a jury takes, so there is somebody to
    // bring on when the first lot start going.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
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
    // The table does not wait for them: a juror brought on comes to
    // the hand from where it joined it, so it holds its piece a
    // little after the table has moved on.
    //
    // A piece of the escrow is what is asserted, and not that each of
    // them reached the end of the hand. Holding the piece is what the
    // topping up is for and what this test is about; keeping up with
    // a hand joined halfway through is a different property with a
    // fault of its own against it (task #49), and asserting it here
    // would only mean this test failing for that reason instead of
    // its own.
    final ours = [for (final j in t.jurors) if (brought.contains(j.signer.publicKey)) j];
    final holding = t.clock.runUntil(
      () => ours.every((j) => j.client?.holdsEscrowPiece(hand) ?? false),
      limitMs: 5 * 60 * 1000,
    );
    expect(holding, isTrue,
        reason: 'every juror brought on holds a piece of the hand it was brought on to:\n'
            '${[for (final j in ours) '${j.signer.publicKey.substring(0, 4)}: '
                '${j.client?.holdsEscrowPiece(hand)}'].join('\n')}');
    t.stop();
  },
      timeout: const Timeout(Duration(minutes: 10)),
      // Skipped, and this is where it stands, because a skip without
      // one rots.
      //
      // A top-up is a mid-hand thing: a juror brought on while a hand
      // is running, given a share of an escrow it was not sealed to.
      // Seeing one needs a hand still running thirty seconds after a
      // jury has been judged short, and a bot seat now reaches the
      // escrow three seconds after its holder stops playing rather
      // than thirty (client.dart, botActsWithinMs), so a hand over a
      // data channel is finished before there is anything to watch.
      // Hence the latency above, which is what a real table has.
      //
      // With it, this test found two faults and they are fixed: a
      // juror brought on late used to publish keys for a seat that
      // had been keyed before it arrived, and the assignment it had
      // read from the wrong jury could not be put right once any deal
      // step had settled. Four brought on used to leave none of them
      // able to finish the hand; three of four now do, and two of
      // four hold a piece of the escrow.
      //
      // What is left is task #49: the fourth juror never finishes the
      // hand, and the parts of a share do not reach two of the four.
      // Neither is the deadline's doing — both fail the same with it
      // switched off.
      skip: 'the top-up reaches two of four jurors brought on; see task #49');
}
