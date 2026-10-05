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

  /// Every one of [among] holds the same record, and it verifies.
  /// [among] is the survivors, unless a client is out of the table
  /// without knowing it — a modified one that stopped applying the
  /// record is still seated as far as it can tell.
  void agreeAmong(SimTable t, Iterable<TableClient> among) {
    final records = [for (final c in among) c.record.map((d) => d.key).toList()];
    for (final r in records) {
      expect(r, records.first, reason: 'every survivor holds the same record');
    }
    final totals = [for (final c in among) c.game.totals];
    for (final s in totals) {
      expect(s, totals.first);
    }
    final first = among.first;
    final v = verifyRecord(t.spec, first.record, juries: first.juries, crypto: crypto, releases: first.releases);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.complete, isTrue, reason: 'a finished sealed game verifies to the end');
    expect(v.winners, first.game.winners);
  }

  void agree(SimTable t) => agreeAmong(t, t.survivors);

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
    // take the other person's hand by subtraction (docs/03-fair-deal.md).
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

  test('nobody online to draw from: the jurors of last resort come up and hold the bot seats', () {
    // The quiet night, which is when a table has bot seats at all:
    // matchmaking gives you bots exactly when it cannot find four
    // people, and that is exactly when there is nobody to draw a jury
    // from. The call brings up the bench, the bench holds the seats,
    // and the bots' hands stay hidden (docs/04-live-play.md).
    final t = SimTable(humans: 2, seed: 21, crypto: crypto, lastResort: true);
    t.start();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.passing), limitMs: 300000), isTrue,
        reason: 'the deal waits for the bench and then completes');
    expect(t.presence!.calls, greaterThan(0), reason: 'the table called for jurors');

    final holders = t.clients.first.botHolders(0);
    expect(holders.length, 2, reason: 'a juror to each bot seat');
    final bench = {for (final j in t.presence!.lastResorts) j.signer.publicKey};
    expect(holders.values.every(bench.contains), isTrue, reason: 'and they are the bench, since nobody else was online');
    for (final c in t.clients) {
      for (var s = 0; s < seatCount; s++) {
        expect(c.game.knowsHand(s), s == c.mySeat, reason: 'seat $s as seen by seat ${c.mySeat}');
      }
    }

    expect(t.run(), isTrue, reason: 'the game plays out');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  /// A table where every seat says it holds the two of clubs nowhere.
  /// Three of them are telling the truth; whichever was dealt the card
  /// is not, and nothing in the deal's proofs can tell them apart
  /// (docs/03-fair-deal.md) — there is nothing to prove about a card
  /// you say you do not hold. [how] is which kind of modified client
  /// they are. The lie lasts one hand: the seat that told it is out
  /// before another is dealt, and the rest play on honestly.
  SimTable liarsTable(Lie how, {int seed = 11}) {
    final t = SimTable(humans: 4, seed: seed, crypto: crypto, jurors: juryToHoldBots);
    for (final c in t.clients) {
      c.lies = how;
      c.changes.listen((_) {
        if (c.game.handNumber > 0) c.lies = null;
      });
    }
    return t;
  }

  /// Hand 0 was given up, unplayed and unscored, and its deal was
  /// opened to say why.
  void gaveUpTheFirstHand(Iterable<TableClient> among) {
    for (final c in among) {
      expect(c.lastHand, isNull, reason: 'a hand nobody could lead has no score sheet');
      final hand0 = c.record.where((d) => d.turn.hand == 0).toList();
      expect(hand0.where((d) => d.turn.isPass || d.turn.isPlay), isEmpty,
          reason: 'not a card was passed or played in it');
      expect(hand0.where((d) => d.turn.isAudit).length, 4, reason: 'and every seat of it was opened');
    }
  }

  test('a seat that disclaims the two of clubs and plays on regardless is booted at the audit it will not answer', () {
    final t = liarsTable(Lie.declare);
    t.start();
    // Three of the four stop before the hand begins; the fourth dealt
    // itself a hand only it can play, which is how it gives itself away.
    expect(t.clock.runUntil(() => t.clients.where((c) => c.pause == Pause.waitingForLead).length == 3, limitMs: 60000), isTrue,
        reason: 'nobody the table can hear claims the lead card');
    final liar = t.clients.firstWhere((c) => c.pause == null);
    // Settling is not simultaneous: the three stop at the lead, and the
    // liar is still finishing the deal it gave itself. Wait for it to
    // get its hand rather than sample the instant the others stopped.
    expect(t.clock.runUntil(() => liar.game.phase == Phase.passing, limitMs: 60000), isTrue,
        reason: 'the modified client alone got a hand out of it');
    final honest = t.clients.where((c) => c != liar).toList();

    // It never answers the audit the others called, and its heartbeats
    // put it behind them for ever — which is not catching up, it is a
    // client that took a path of its own. The clock has it.
    expect(t.clock.runUntil(() => honest.every((c) => c.holders[liar.mySeat!] is BotSeat), limitMs: 200000), isTrue,
        reason: 'the seat is booted at the turn it will not answer');
    expect(t.clock.runUntil(() => honest.every((c) => c.game.handNumber > 0), limitMs: 60000), isTrue,
        reason: 'and the hand nobody could lead is given up for one they can');
    gaveUpTheFirstHand(honest);

    expect(t.clock.runUntil(() => honest.every((c) => c.done), limitMs: 3 * 60 * 60 * 1000), isTrue,
        reason: 'the other three finish the game');
    // The one that was removed never took in its own removal: it is at
    // the hand it dealt itself, holding a record the table left behind.
    expect(liar.game.handNumber, 0);
    agreeAmong(t, honest);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a seat that disclaims the two of clubs and waits with the rest is caught by the deal it helped open', () {
    final t = liarsTable(Lie.hide);
    t.start();
    // Nothing this one does is out of step: it stops when the table
    // stops and audits when the table audits. What it cannot do is not
    // have been dealt the card.
    expect(t.clock.runUntil(() => t.clients.every((c) => c.pause == Pause.waitingForLead), limitMs: 60000), isTrue,
        reason: 'the whole table stops before the hand begins');
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.handNumber > 0), limitMs: 120000), isTrue,
        reason: 'the hand is opened, given up, and the next one dealt');
    gaveUpTheFirstHand(t.clients);
    for (final c in t.clients) {
      expect(c.pause, isNull, reason: 'and the table is moving again');
    }

    // And the seat the open deal names is out, at the first turn of its
    // own that opened: not the turn it lied at, which settled long
    // before the cards said so.
    expect(t.clock.runUntil(() => t.survivors.length == 3, limitMs: 120000), isTrue, reason: 'the liar is removed');
    final out = t.clients.firstWhere((c) => !c.amSeated);
    expect(out.game.handNumber, 1, reason: 'removed in the hand after the one it spoiled');
    expect(t.run(), isTrue, reason: 'the other three finish the game');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a pass sealed to nothing gets no further than its own turn, and the clock has the seat', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto, jurors: juryToHoldBots);
    final sealer = t.clients.first;
    sealer.lies = Lie.seal;
    sealer.changes.listen((_) {
      if (sealer.game.handNumber > 0) sealer.lies = null;
    });
    final into = (0 + PassDirection.forHand(0).seatOffset) % seatCount;
    final receiver = t.clients.firstWhere((c) => c.mySeat == into);
    // Not t.survivors: that is every client that still believes it is
    // seated, and this one's record parts from the table's at the pass
    // it spoiled, so whether it ever takes in its own removal is the
    // deal's business. The three that did not lie are the table.
    final honest = t.clients.where((c) => c != sealer).toList();
    t.start();

    // Sealing three cards to nothing is caught by every seat, not only
    // the receiver: every seat checks the argument beside a seal
    // (docs/03-fair-deal.md), so the pass is refused where it
    // is made — the seat is left at its own turn with nothing settled,
    // and the clock takes it there.
    expect(t.clock.runUntil(() => t.clients.skip(1).every((c) => c.holders[0] is BotSeat), limitMs: 300000), isTrue,
        reason: 'the pass never carries, and the seat goes at the turn it was made at');
    expect(receiver.amSeated, isTrue, reason: 'and the seat it was aimed at is untouched');
    expect(t.clock.runUntil(() => honest.every((c) => c.game.handNumber > 0 || c.game.phase == Phase.playing), limitMs: 120000),
        isTrue,
        reason: 'the hand is played, not given up: the escrow opens what the seal did not');

    expect(t.clock.runUntil(() => honest.every((c) => c.done), limitMs: 3 * 60 * 60 * 1000), isTrue,
        reason: 'the other three finish the game');
    agreeAmong(t, honest);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a person who leaves mid-hand has their hand opened from escrow, and the bot plays it out', () {
    final t = SimTable(humans: 4, seed: 8, crypto: crypto, jurors: 4);
    t.people[2].exitAt = Moment.offTurn;
    t.people[2].exit = Exit.leave;
    t.start();
    // The hand they left is in play still, and this deal was built
    // with their seat a person's: nobody holds it, so the escrow
    // opens it to the table and the bot finishes the hand in the
    // open. That opening is the one hand's only.
    int? leftAt;
    expect(t.clock.runUntil(() {
      if (!t.survivors.every((c) => c.seatStateOf(2) == SeatState.left)) return false;
      leftAt ??= t.survivors.first.game.handNumber;
      return t.survivors.every((c) => c.game.handNumber == leftAt && c.game.knowsHand(2));
    }, limitMs: 300000), isTrue, reason: 'the escrow opens the hand they left, in the hand they left it');
    expect(t.run(), isTrue);
    expect(t.people[2].gone, isTrue);
    expect(t.survivors.length, 3);
    for (final c in t.survivors) {
      expect(c.seatStateOf(2), SeatState.left);
      // From the next deal on the seat is a bot a juror holds, and a
      // bot seat is nobody at the table's to see (docs/04-live-play.md).
      expect(c.game.knowsHand(2), isFalse, reason: 'a jury-held bot seat is not the players\' to see');
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

  test('a lone person who leaves during the pass saw no bot\'s hand, and holds no pause', () {
    final t = SimTable(humans: 1, seed: 11, crypto: crypto, jurors: juryToHoldBots);
    t.people[0].exitAt = Moment.duringPass;
    t.people[0].exit = Exit.leave;
    final me = t.clients.first;
    var sawABot = false;
    me.changes.listen((_) {
      for (var s = 1; s < seatCount; s++) {
        if (me.game.knowsHand(s)) sawABot = true;
      }
    });
    t.start();
    // The bots' hands are the jury's, never dealt in the open, so the
    // one person at the table never sees one, leaving or not. And with
    // nobody left the jurors are serving nobody: they stop, and their
    // duty lets the table go (juror_duty.dart).
    expect(t.clock.runUntil(() => t.people[0].gone, limitMs: 10 * 60 * 1000), isTrue, reason: me.describe());
    expect(sawABot, isFalse);
    expect(me.pause, isNull);
    List<TableClient> jurors() => [for (final j in t.jurors) if (j.client != null) j.client!];
    expect(jurors(), isNotEmpty);
    expect(t.clock.runUntil(() => jurors().every((c) => !c.serving), limitMs: 10 * 60 * 1000), isTrue,
        reason: jurors().map((c) => c.describe()).join('\n'));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  for (final exit in [Exit.leave, Exit.crash]) {
    test('a person who ${exit == Exit.leave ? 'leaves' : 'crashes'} during the pass, after a pass into their seat, has that pass opened with their hand', () {
      // Three people: the one passing into the leaver is a person, so
      // the pass is sealed to the leaver and taken as unknown by all —
      // until the leaver's secret is rebuilt and the bot in the seat
      // needs the hand, pass included.
      final t = SimTable(humans: 3, seed: 12, crypto: crypto, jurors: 4);
      // Slower than the others, so a person's pass reaches the leaver
      // before the leaver's own; and the moment asks for a person's.
      t.people[1].thinkMs = 3000;
      t.people[1].exitAt = Moment('during the pass, after a person\'s pass into me', (c) {
        if (!c.awaitingMyPass) return false;
        final from = (c.mySeat! - c.game.passDirection.seatOffset) % seatCount;
        return c.spec.seats[from] is HumanSeat && c.game.hasPassed(from);
      });
      t.people[1].exit = exit;
      t.start();
      // The pass was sealed to a seat whose secret the escrow rebuilds:
      // the hand it lands in opens to the table, pass included, and the
      // bot plays it out there.
      int? leftAt;
      expect(t.clock.runUntil(() {
        if (!t.survivors.every((c) => c.seatStateOf(1) != SeatState.human)) return false;
        leftAt ??= t.survivors.first.game.handNumber;
        return t.survivors.every((c) => c.game.handNumber == leftAt && c.game.knowsHand(1));
      }, limitMs: 300000), isTrue, reason: 'the pass into the seat is opened with the hand it was sealed to');
      expect(t.run(), isTrue);
      expect(t.people[1].gone, isTrue, reason: 'the moment came');
      for (final c in t.survivors) {
        expect(c.game.knowsHand(1), isFalse, reason: 'the seat is a bot the jury holds by the end');
        expect(c.pause, isNull);
      }
      agree(t);
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

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
