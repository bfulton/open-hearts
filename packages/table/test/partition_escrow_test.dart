/// A seat given to the escrow where the jury could not hear it.
///
/// A person whose clock says a bot seat's juror is out claims the seat
/// for the escrow, and at a table of one person their word carries it.
/// The turn stays open, for the card the escrow's custodians now owe the
/// seat. Claimed across a partition from the jurors, the claim never
/// reached the custodians: once it carried, the person had nothing at
/// the turn left to say again, and both sides stood at the same step,
/// so no heartbeat had either behind. The person waited on the
/// custodians and the custodians on the seat's own juror, for good
/// (found by the sealed chaos walk at seed 4, nine strangers).
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

import 'sealed.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a seat given to the escrow across a partition from the jurors is played once the partition heals', () {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, target: 1, lastResort: true);
    final ada = t.people[0].client;
    t.start();
    expect(t.clock.runUntil(() => ada.game.phase == Phase.playing && ada.game.tricksPlayed >= 2 && ada.game.currentSeat == 0,
            limitMs: 20 * 60 * 1000),
        isTrue);
    // The seat after the person's: its juror gone for good, and the
    // person cut off from every other juror ten seconds on, well before
    // their clock gives the seat up.
    const seat = 1;
    final juror = ada.botHolders(0)[seat]!;
    t.net.crash(juror);
    final others = {for (final j in t.jurors) j.signer.publicKey}..remove(juror);
    final at = t.clock.nowMs;
    var parted = false;
    expect(
        t.clock.runUntil(() {
          if (!parted && t.clock.nowMs - at > 10000) {
            parted = true;
            t.net.partition([
              {ada.signer.publicKey},
              others
            ]);
          }
          return ada.escrowedAt(0).containsKey(seat);
        }, limitMs: 5 * 60 * 1000),
        isTrue,
        reason: ada.describe());
    expect(parted, isTrue, reason: 'given up across the partition');
    final custodians = [for (final j in t.jurors) if (j.client case final c? when others.contains(j.signer.publicKey)) c];
    expect(custodians.every((c) => c.escrowedAt(0).isEmpty), isTrue, reason: 'and the jurors not told of it');
    t.clock.advance(30000);
    t.net.heal();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue,
        reason: 'the game played out:\n${ada.describe()}\n${[for (final c in custodians) c.describe()].join('\n')}');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
