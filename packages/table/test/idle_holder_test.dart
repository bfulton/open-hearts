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
    // Past the seat's allowance, and not so far past it that the hand
    // is over before anything is looked at: three allowances of
    // fifteen seconds outlasted the rest of this one, and what was
    // looked at was the next hand's deal.
    t.clock.advance(TableClient.botActsWithinMs + 6000);
    expect(c.jury.live, greaterThan(0), reason: 'the jury is still being heard');

    // And the hand goes on rather than sitting at that seat's turn.
    expect(t.clock.runUntil(() => c.game.tricksPlayed > at + 1, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the table played past the seat its holder had stopped playing:\n${c.describe()}');
    expect(c.game.handNumber, hand, reason: 'still the hand the seat was taken in');
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

  // The same juror in the deal. A play or a pass has fifteen seconds; a
  // deal step had no allowance at all, so a juror heard and idle with
  // its seat's keys owed held the deal for good — only silence was
  // ever caught there, and it was never silent.
  test('a bot seat whose holder is heard but never takes its deal step gives the hand up, and the game goes on', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final c = t.clients.first;
    // Asleep from the moment the hand's seats are named, before any
    // of their keys could have gone out.
    expect(t.clock.runUntil(() => c.botHolders(c.game.handNumber).isNotEmpty, limitMs: 60 * 1000), isTrue);
    final hand = c.game.handNumber;
    final seat = c.botHolders(hand).keys.first;
    t.net.doze(c.botHolders(hand)[seat]!);
    expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the hand was given up rather than waited on:\n${c.describe()}');
    expect(c.jury.live, greaterThan(0), reason: 'with the jury heard from all along');
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out: ${c.describe()}');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And the hand after it. The draw for it leaves the idle juror out
  // and so takes one the table has not had: summoned, connecting, and
  // replaying a hand the record says nothing more about, since a hand
  // given up in its deal is each side's own judgement. That juror has
  // to work out that the hand is over ([TableClient] reads it from the
  // table's heartbeats), and the deal it was drawn for has to wait for
  // it to arrive rather than count the arriving against it — on the
  // table's clock, the second hand went the way of the first, and the
  // juror that was only late was left out of the next draw.
  test('a juror drawn for the hand after one given up undealt arrives, and deals it', () {
    final t = SimTable(humans: 2, seed: 1, crypto: crypto, jurors: jurySize + 1, target: 1);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.botHolders(c.game.handNumber).isNotEmpty, limitMs: 60 * 1000), isTrue);
    final drawn = c.juries.first.event.jurors.toSet();
    final first = c.botHolders(0);
    t.net.doze(first[first.keys.first]!);
    expect(t.clock.runUntil(() => c.game.handNumber == 1 && c.botHolders(1).isNotEmpty, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the first hand was given up: ${c.describe()}');
    // The case is a newcomer holding a seat; a seed that drew only
    // jurors the table already had would not be testing it.
    expect(c.botHolders(1).values.where((k) => !drawn.contains(k)), isNotEmpty, reason: 'a juror new to the table holds a seat');
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing || c.game.handNumber > 1, limitMs: 2 * 60 * 1000), isTrue);
    expect(c.game.handNumber, 1, reason: 'the second hand was dealt, not given up after the first: ${c.describe()}');
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out: ${c.describe()}');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
