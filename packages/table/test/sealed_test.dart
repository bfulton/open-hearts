/// Sealed tables on the simulator: the verifiable deal run for real —
/// every proof made and checked — on the virtual clock, with people
/// leaving mid-hand and the jury holding the pieces that open what
/// they left behind.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  void agree(SimTable t) {
    final records = [for (final c in t.survivors) c.record.map((d) => d.key).toList()];
    for (final r in records) {
      expect(r, records.first, reason: 'every survivor holds the same record');
    }
    final totals = [for (final c in t.survivors) c.game.totals];
    for (final s in totals) {
      expect(s, totals.first);
    }
    final first = t.survivors.first;
    final v = verifyRecord(t.spec, first.record, juries: first.juries, crypto: crypto);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.complete, isTrue, reason: 'a finished sealed game verifies to the end');
    expect(v.winners, first.game.winners);
  }

  for (final humans in [1, 2, 4]) {
    test('$humans human(s) and ${4 - humans} bot(s) play a whole sealed game, and it verifies', () {
      final t = SimTable(humans: humans, seed: 7, crypto: crypto, jurors: 2);
      t.start();
      // The first hand dealt: each person sees its own cards and the
      // bots', and nothing of the other people's.
      expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.passing), limitMs: 60000), isTrue,
          reason: 'the first deal completes');
      for (final c in t.clients) {
        expect(c.record.where((d) => d.turn.isDeal).length, humans * 4, reason: 'four deal steps per person, none per bot');
        for (var s = 0; s < seatCount; s++) {
          final own = s == c.mySeat;
          final bot = t.spec.seats[s] is BotSeat;
          expect(c.game.knowsHand(s), own || bot, reason: 'seat $s as seen by seat ${c.mySeat}');
          expect(c.game.handSizeOf(s), 13);
        }
      }
      expect(t.run(), isTrue, reason: 'every client reaches the end of the game');
      agree(t);
      expect(t.clients.first.pause, isNull);
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('a person who leaves mid-hand has their hand opened from escrow, and the bot plays it out', () {
    final t = SimTable(humans: 4, seed: 8, crypto: crypto, jurors: 4);
    t.people[2].exitAt = Moment.offTurn;
    t.people[2].exit = Exit.leave;
    t.start();
    expect(t.run(), isTrue);
    expect(t.people[2].gone, isTrue);
    expect(t.survivors.length, 3);
    for (final c in t.survivors) {
      expect(c.seatStateOf(2), SeatState.left);
      expect(c.game.knowsHand(2), isTrue, reason: 'the leaver\'s seat is a bot whose hand everyone sees');
    }
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('at a table of two, a crash on turn is settled by the jury and the hand opened with a juror\'s piece', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: 4);
    t.people[1].exitAt = Moment.onOwnTurn;
    t.people[1].exit = Exit.crash;
    t.start();
    expect(t.run(), isTrue);
    expect(t.survivors.length, 1);
    final c = t.survivors.first;
    expect(c.seatStateOf(1), isIn([SeatState.booted, SeatState.absent]));
    expect(c.pause, isNull);
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a person who leaves during the deal is a bot from there, and the deal goes on', () {
    final t = SimTable(humans: 3, seed: 10, crypto: crypto, jurors: 4);
    t.people[1].exitAt = Moment('during the deal', (c) => c.game.phase == Phase.dealing && c.deal!.hasKeys(1) && c.deal!.deck == null);
    t.people[1].exit = Exit.leave;
    t.start();
    expect(t.run(), isTrue);
    expect(t.people[1].gone, isTrue);
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
