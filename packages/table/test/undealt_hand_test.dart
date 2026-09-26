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

    // And the record of it checks out. The hand ends in its deal, with
    // steps owed and no audit, and the next hand follows; the verifier
    // took that for a deal left unfinished and turned the game down,
    // where the design has it take an abandoned hand as over
    // (docs/04-live-play.md, "When quorum is lost anyway").
    test('a game with a hand given up undealt checks out${afterKeys ? ', keys out' : ', before its keys'}', () {
      // Played to a point, so the hand after the one given up ends it.
      final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1);
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
      t.net.goOffline(held[seat]!);
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
          reason: 'the game was played out: ${c.describe()}');
      expect(c.game.handNumber, greaterThan(hand), reason: 'the hand was given up and another played');
      for (final c in t.clients) {
        final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
        expect(v.ok, isTrue, reason: v.reason);
        expect(v.complete, isTrue, reason: v.reason);
      }

      t.stop();
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  // A table whose only held seat's juror goes before it says a word:
  // three people and one bot. Nothing in the record speaks for the
  // seat, so the replay has no juror's step to tell it the seat was
  // held at all, and took it for one everybody works out — dealt its
  // keys in public and found the deal stopped at a person's shuffle.
  // The hand's draw names a juror for it, and a hand stopped at the
  // keys with a named juror silent is the one the table gave up.
  test('a hand given up because its one held seat never spoke checks out', () {
    final t = SimTable(humans: 3, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1);
    t.start();
    final c = t.clients.first;
    t.clock.runUntil(() => c.botHolders(c.game.handNumber).isNotEmpty, limitMs: 5 * 60 * 1000);
    final hand = c.game.handNumber;
    final held = c.botHolders(hand);
    expect(held.length, 1);
    expect(c.keyedBy(hand), isEmpty, reason: 'the seat has said nothing yet');
    t.net.goOffline(held.values.single);
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 15 * 60 * 1000), isTrue,
        reason: 'the game went on: ${c.describe()}');
    expect(c.game.handNumber, greaterThan(hand), reason: 'the hand was given up and another played');
    expect(c.record.where((d) => d.turn.hand == hand && d.event.seat == held.keys.single), isEmpty,
        reason: 'nothing in the record speaks for the seat in the hand given up');
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And only that. A hand whose held seats have all said their last
  // word on the deal owes nothing to any juror, and a deal stopped
  // there — at a person's declaration — is not one the table gives up:
  // the person is removed, the record shows it, and the escrow deals
  // on. A record that walks away from such a deal to the next hand is
  // a hand somebody did not want dealt, and the verifier says so.
  test('a deal stopped with every held seat done is not a hand given up', () {
    // Two hands at least: nobody reaches 27 in one.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 27);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.done, limitMs: 20 * 60 * 1000), isTrue, reason: 'the game was played out: ${c.describe()}');
    expect(verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases).ok, isTrue);
    final humans = {for (var s = 0; s < seatCount; s++) if (t.spec.seats[s] is HumanSeat) s};
    // The first hand's deal without the people's declarations, and
    // nothing of the hand after it; the rest of the game as it was.
    final cut = [
      for (final d in c.record)
        if (d.turn.hand != 0 ||
            (d.turn.isDeal && !d.removal && !(d.turn.dealRound == TurnId.dealRounds - 1 && humans.contains(d.turn.dealSeat))))
          d,
    ];
    final held = c.botHolders(0).keys;
    expect(held, isNotEmpty, reason: 'the hand had seats a juror held');
    expect(cut.where((d) => d.turn.hand == 0 && d.turn.dealRound == TurnId.dealRounds - 1).map((d) => d.turn.dealSeat).toSet(),
        containsAll(held), reason: 'every held seat declared');
    final v = verifyRecord(t.spec, cut, juries: c.juries, crypto: crypto, releases: c.releases);
    expect(v.ok, isFalse, reason: 'a deal walked away from with nothing owed by a juror was taken for a hand given up');
    // At that hand. Taken for a hand given up, the record fails later
    // too, for the hand the game is then short of — which says the
    // same words about a different hand.
    expect(v.reason, startsWith('hand 0: the deal is not complete'));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 20)));

  // The seat's juror goes while the deal is elsewhere: every key is in,
  // a person is holding up the shuffles, and by the time the shuffles
  // come round to the seat it has been the escrow's for a minute and
  // more. It was given up with no deal turn open, so the hand was not;
  // and when its shuffle opened, nobody could take it — the players
  // cannot open a seat whose pieces are sealed to the jury, and a juror
  // does not say a held seat's deal steps. The table sat there for
  // good. A held seat with any step of the deal still to come takes
  // the hand with it, whichever turn is open when it goes.
  test('a bot seat whose juror goes before its deal turn comes round still gives the hand up', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1);
    t.start();
    final c = t.clients.first;
    final other = t.clients.elementAt(1);
    t.clock.runUntil(() => c.botHolders(c.game.handNumber).length == 2, limitMs: 5 * 60 * 1000);
    final hand = c.game.handNumber;
    final held = c.botHolders(hand);
    final last = held.keys.reduce((a, b) => a > b ? a : b);
    expect(t.clock.runUntil(() => [0, 1, 2, 3].every((s) => other.deal?.hasKeys(s) ?? false), limitMs: 60000), isTrue,
        reason: 'every key is in');
    // Seat 1 shuffles second and is not there to; the last bot seat
    // shuffles last, and its juror is not there either.
    t.net.goOffline(t.signers[1].publicKey);
    t.net.goOffline(held[last]!);
    expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the hand was given up: ${c.describe()}');
    expect(c.game.totals.every((n) => n == 0), isTrue, reason: 'an undealt hand scores nothing');
    expect(t.clock.runUntil(() => c.done, limitMs: 15 * 60 * 1000), isTrue, reason: 'the game went on: ${c.describe()}');
    final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
