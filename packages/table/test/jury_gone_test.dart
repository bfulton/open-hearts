/// A table whose whole jury has gone, stopped at a bot seat a juror
/// held.
///
/// A held seat's moves are its juror's to say, or — once the table
/// gives the seat to the escrow — the first custodian's still being
/// heard from. A player never says one: the seat's pieces are sealed
/// to the jury, and no player will ever hold its key. So with every
/// juror gone the players reach the seat's turn and wait. A table
/// waiting on a jury it does not have says so, as it does when nobody
/// is online to draw one from (jury_test.dart), and goes on when a
/// juror comes back.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('the whole jury gone at a held seat\'s turn: the table says it waits for the jury, and goes on when one is back', () {
    // Exactly a jury's worth online, so there is nobody to draw again.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final held = c.botHolders(c.game.handNumber);
    expect(held, isNotEmpty);
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    expect(t.clock.runUntil(() => c.pause == Pause.waitingForJury, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table said what it was waiting for:\n${c.describe()}');
    expect(c.tableState, TableState.pausedForJury);
    final seat = c.game.currentSeat;
    expect(held.keys, contains(seat), reason: 'it stopped at a held seat');
    final at = c.game.tricksPlayed * seatCount + c.game.trick.length;

    // The seat's own juror back. The table gave its seat to the escrow
    // while it was away, and it is the one juror of the escrow left, so
    // it plays the seat on as the escrow's (escrow_on_record_test.dart).
    final hand = c.game.handNumber;
    t.net.comeOnline(held[seat]!);
    expect(
        t.clock.runUntil(() => c.game.tricksPlayed * seatCount + c.game.trick.length > at, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table went on once a juror was back:\n${c.describe()}');
    expect(c.pause, isNot(Pause.waitingForJury), reason: 'and stopped saying it waited: ${c.describe()}');
    expect(c.escrowedAt(hand), contains(seat), reason: 'the seat went to the escrow while the jury was away');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
