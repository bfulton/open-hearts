/// A juror that is heard from and does nothing.
///
/// Silence was the only way a bot seat could be taken off its holder,
/// and silence is not the only way a holder fails. A device whose
/// clock runs and whose work does not — a tab starved of a processor,
/// a phone in a pocket — goes on heartbeating while the seat in front
/// of it never moves. The custodians that stopped hearing it gave
/// their pieces up; the peers still hearing it went on waiting; and a
/// hand sat at one turn with the seat's own device apparently present.
///
/// It is what the four-browser suite kept failing on, with four
/// headless browsers and a relay sharing four cores. Heard from is
/// not the same as playing.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  test('a bot seat whose holder is heard but never plays is given to the escrow, and the hand goes on', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4);
    t.start();
    expect(t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the hand was dealt');
    final c = t.clients.first;
    final hand = c.game.handNumber;
    final seat = c.botHolders(hand).keys.first;
    final holder = c.botHolders(hand)[seat]!;

    // Its heartbeats go on; everything else it would say is dropped
    // where it is said. To every other side it is present and idle.
    t.net.doze(holder);
    final at = c.game.tricksPlayed;

    // It keeps being heard — this is the whole point of the case, and
    // without it the seat would go for silence as it always could.
    t.clock.advance(TableClient.botActsWithinMs * 3);
    expect(c.jury.live, greaterThan(0), reason: 'the jury is still being heard');

    // And the hand goes on rather than sitting at that seat's turn.
    expect(t.clock.runUntil(() => c.game.tricksPlayed > at + 1, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the table played past the seat its holder had stopped playing:\n${c.describe()}');
    expect(c.deal!.gone, contains(seat), reason: 'the seat went to the escrow');
    expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'and the hand was played out: ${c.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And the record says so, which is the other half. The seat's audit
  // is settled at every side with nothing said — its secret is out in
  // the clear already, the escrow's pieces released at the hand's end
  // — so the verifier has to rebuild it from those pieces the way the
  // table did. It rebuilt only a person's that way, one the record
  // shows removed, and turned down the finished game: every card of
  // the seat unopened, though every side at the table had opened it.
  test('the record of a hand whose bot seat went to the escrow checks out to the last card', () {
    // A game of one hand, so the record is a finished one.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1);
    t.start();
    expect(t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the hand was dealt');
    final c = t.clients.first;
    final hand = c.game.handNumber;
    final seat = c.botHolders(hand).keys.first;
    t.net.doze(c.botHolders(hand)[seat]!);
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the game was played out: ${c.describe()}');
    expect(c.deal!.gone, contains(seat), reason: 'the seat went to the escrow');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
