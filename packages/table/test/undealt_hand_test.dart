/// A hand whose deal cannot be finished is given up, not waited on.
///
/// A bot seat's juror holds the key its deal steps are made with. If
/// that juror goes while a deal turn of the seat is still open, nobody
/// can take that step: the holder drew the key, and where the keys
/// never went out there is not even an escrow holding pieces of it.
/// The hand is given up unscored and the next dealt in its place
/// (docs/04-live-play.md, "When quorum is lost anyway").
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  // Both sides of it: the holder goes before its keys are out, so
  // there is no escrow at all; and after them, so there is one and it
  // still cannot make the shuffle that comes next.
  for (final afterKeys in [false, true]) {
    test('a bot seat whose juror goes mid-deal gives the hand up${afterKeys ? ', keys out' : ', before its keys'}', () {
      final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
      t.start();
      final c = t.clients.first;
      t.clock.runUntil(() => c.botHolders(c.game.handNumber).isNotEmpty, limitMs: 5 * 60 * 1000);
      final hand = c.game.handNumber;
      final held = c.botHolders(hand);
      final seat = held.keys.first;
      if (afterKeys) {
        expect(t.clock.runUntil(() => c.keyedBy(hand).containsKey(seat), limitMs: 2 * 60 * 1000), isTrue,
            reason: 'the seat got its keys out before its juror went');
      }
      expect(c.game.phase, Phase.dealing, reason: 'still in the deal when the holder goes');
      t.net.goOffline(held[seat]!);

      // The hand is given up rather than waited on, and unscored:
      // nothing was passed and nothing was played.
      expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 5 * 60 * 1000), isTrue,
          reason: 'the hand was given up: ${c.describe()}');
      expect(c.game.totals.every((n) => n == 0), isTrue, reason: 'an undealt hand scores nothing');

      // And the table goes on playing rather than giving up hand after
      // hand: the next deal draws a jury again, without the one that
      // went.
      expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 10 * 60 * 1000), isTrue,
          reason: 'a hand was dealt in its place: ${c.describe()}');
      expect(c.botHolders(c.game.handNumber).values, isNot(contains(held[seat])),
          reason: 'the juror that went is not holding a seat of the new hand');
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
