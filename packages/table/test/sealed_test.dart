/// Sealed tables on the simulator: the verifiable deal run for real —
/// every proof made and checked — on the virtual clock, with people
/// leaving mid-hand and the jury holding the pieces that open what
/// they left behind. Whole games and the seats the jury holds here;
/// a seat that lies about its deal in sealed_lies_test.dart, people
/// leaving in sealed_departures_test.dart.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

import 'sealed.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('four people play a whole sealed game, and it verifies', () {
    final t = SimTable(humans: 4, seed: 7, crypto: crypto, jurors: 2);
    t.start();
    // The first hand dealt: each person sees its own cards and nothing
    // of the other people's.
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.passing), limitMs: 60000), isTrue,
        reason: 'the first deal completes');
    for (final c in t.clients) {
      expect(c.record.where((d) => d.turn.isDeal).length, 16, reason: 'four deal steps per person');
      for (var s = 0; s < seatCount; s++) {
        expect(c.game.knowsHand(s), s == c.mySeat, reason: 'seat $s as seen by seat ${c.mySeat}');
        expect(c.game.handSizeOf(s), 13);
      }
    }
    expect(t.run(), isTrue, reason: 'every client reaches the end of the game');
    agree(t);
    expect(t.clients.first.pause, isNull);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  for (final humans in [1, 2, 3]) {
    test('$humans human(s) and too few jurors to hold ${4 - humans} bot(s): the hand waits, and is never dealt in the open', () {
      // Two jurors cannot hold the bot seats (juryToHoldBots), and
      // nobody else is coming. A bot's hand dealt in the open would be
      // the table's to see, so the table waits and says so.
      final t = SimTable(humans: humans, seed: 7, crypto: crypto, jurors: 2);
      t.start();
      t.clock.runUntil(() => t.clock.nowMs >= 10 * 60 * 1000, limitMs: 10 * 60 * 1000 + 1);
      for (final c in t.clients) {
        expect(c.shortOfJurors, isTrue, reason: 'it says what it is waiting for');
        expect(c.dealOf(0), isNull, reason: 'no deal started at ten minutes');
        expect(c.game.phase, isNot(Phase.passing));
        for (var s = 0; s < seatCount; s++) {
          if (s != c.mySeat) expect(c.game.knowsHand(s), isFalse, reason: 'seat $s as seen by seat ${c.mySeat}');
        }
      }
      expect(t.clients.first.record.where((d) => d.removal), isEmpty, reason: 'nobody is put out for waiting');
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('a bot seat a juror holds is played by that juror, and no player sees its hand', () {
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: 4);
    t.start();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.passing), limitMs: 120000), isTrue,
        reason: 'the deal completes with two seats held by jurors');

    // The point of the whole change: a person sees its own cards and
    // nobody else's, where today it would see both bots' as well and
    // take the other person's hand by subtraction (docs/explanation/fair-deal.md).
    for (final c in t.clients) {
      for (var s = 0; s < seatCount; s++) {
        expect(c.game.knowsHand(s), s == c.mySeat, reason: 'seat $s as seen by seat ${c.mySeat}');
      }
      expect(c.deal!.knowsSecret(2), isFalse, reason: 'a bot seat\'s key is not a player\'s to compute');
      expect(c.deal!.knowsSecret(3), isFalse);
    }

    // And the jurors that hold them do see them — one seat each, so no
    // juror holds enough of the deck to subtract either.
    final holders = t.clients.first.botHolders(0);
    expect(holders.length, 2, reason: 'a juror to each bot seat');
    expect(holders.values.toSet().length, 2, reason: 'and not the same juror twice');
    for (final held in holders.entries) {
      final d = t.jurors.firstWhere((j) => j.signer.publicKey == held.value).client!.deal!;
      expect(d.knowsSecret(held.key), isTrue, reason: 'the juror holding seat ${held.key} drew its key');
      for (final other in holders.keys) {
        if (other != held.key) {
          expect(d.knowsSecret(other), isFalse, reason: 'and holds no more of the deck than its own seat');
        }
      }
    }

    expect(t.run(), isTrue, reason: 'the game plays out');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('nobody online to draw from: the backup jurors come up and hold the bot seats', () {
    // The quiet night, which is when a table has bot seats at all:
    // matchmaking gives you bots exactly when it cannot find four
    // people, and that is exactly when there is nobody to draw a jury
    // from. The call brings up the backup jurors, they hold the seats,
    // and the bots' hands stay hidden (docs/explanation/live-play.md).
    final t = SimTable(humans: 2, seed: 21, crypto: crypto, lastResort: true);
    t.start();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.passing), limitMs: 300000), isTrue,
        reason: 'the deal waits for the backup jurors and then completes');
    expect(t.presence!.calls, greaterThan(0), reason: 'the table called for jurors');

    final holders = t.clients.first.botHolders(0);
    expect(holders.length, 2, reason: 'a juror to each bot seat');
    final bench = {for (final j in t.presence!.lastResorts) j.signer.publicKey};
    expect(holders.values.every(bench.contains), isTrue, reason: 'and they are backup jurors, since nobody else was online');
    for (final c in t.clients) {
      for (var s = 0; s < seatCount; s++) {
        expect(c.game.knowsHand(s), s == c.mySeat, reason: 'seat $s as seen by seat ${c.mySeat}');
      }
    }

    expect(t.run(), isTrue, reason: 'the game plays out');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
