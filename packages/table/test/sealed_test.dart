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

  /// A table where every seat says it holds the two of clubs nowhere.
  /// Three of them are telling the truth; whichever was dealt the card
  /// is not, and nothing in the deal's proofs can tell them apart
  /// (docs/03-fair-deal.md) — there is nothing to prove about a card
  /// you say you do not hold. [how] is which kind of modified client
  /// they are. The lie lasts one hand: the seat that told it is out
  /// before another is dealt, and the rest play on honestly.
  SimTable liarsTable(Lie how, {int seed = 11}) {
    final t = SimTable(humans: 4, seed: seed, crypto: crypto, jurors: 2);
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
    expect(liar.game.phase, Phase.passing, reason: 'the modified client alone got a hand out of it');
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

  /// A table where seat 0 seals its pass of the first hand to nothing:
  /// three cards of the right shape that the receiver will never open,
  /// and that nobody else can tell from an honest pass
  /// (docs/03-fair-deal.md). [how] says whether it answers when it is
  /// asked. Only the first hand: what the table does about it is the
  /// point, not how long it can keep doing it.
  SimTable sealersTable(Lie how, {int seed = 3}) {
    final t = SimTable(humans: 4, seed: seed, crypto: crypto, jurors: 2);
    final sealer = t.clients.first;
    sealer.lies = how;
    sealer.changes.listen((_) {
      if (sealer.game.handNumber > 0) sealer.lies = null;
    });
    return t;
  }

  test('a pass sealed to nothing: the receiver says so, the passer shows the three, and the hand goes on', () {
    final t = sealersTable(Lie.seal);
    final into = (0 + PassDirection.forHand(0).seatOffset) % seatCount;
    final receiver = t.clients.firstWhere((c) => c.mySeat == into);
    final said = <String>[];
    receiver.log = said.add;
    t.start();

    // The receiver cannot open three of its own cards, so it cannot
    // play them, and the table would take its seat for a fault it did
    // not commit. It says so instead.
    expect(t.clock.runUntil(() => said.any((l) => l.contains('will not open')), limitMs: 120000), isTrue,
        reason: 'the receiver finds three cards it cannot open');
    expect(t.clock.runUntil(() => said.any((l) => l.contains('showed in the clear')), limitMs: 120000), isTrue,
        reason: 'and the passer answers by showing them');
    expect(t.clock.runUntil(() => receiver.game.phase == Phase.playing, limitMs: 60000), isTrue,
        reason: 'which puts the receiver back in the hand');

    expect(t.run(), isTrue, reason: 'the game finishes');
    expect(t.survivors, hasLength(4), reason: 'and nobody lost a seat over it');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a pass sealed to nothing and no answer: the hand is given up, and the passer loses its seat', () {
    final t = sealersTable(Lie.sealNoAnswer);
    final sealer = t.clients.first;
    final into = (0 + PassDirection.forHand(0).seatOffset) % seatCount;
    final receiver = t.clients.firstWhere((c) => c.mySeat == into);
    t.start();

    // Only the passer could open those three, and it will not. The
    // receiver cannot play what it cannot see, removing it changes
    // nothing — a bot playing its hand cannot see them either — and a
    // table waiting on a turn that cannot come is the one thing that
    // must not happen. So the hand is opened, given up, and dealt
    // again without the seat that broke it.
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.handNumber > 0), limitMs: 300000), isTrue,
        reason: 'the hand is given up and the next one dealt');
    for (final c in t.clients.where((c) => c.amSeated)) {
      expect(c.lastHand, isNull, reason: 'a hand nobody could finish has no score sheet');
      final hand0 = c.record.where((d) => d.turn.hand == 0).toList();
      expect(hand0.where((d) => d.turn.isPlay), isEmpty, reason: 'and nothing of it was played');
      expect(hand0.where((d) => d.turn.isAudit).length, 4, reason: 'every seat of it was opened, which is how anyone can tell');
    }
    expect(t.clock.runUntil(() => !sealer.amSeated, limitMs: 120000), isTrue, reason: 'the passer is out');
    expect(receiver.amSeated, isTrue, reason: 'and the seat it did it to is not');

    expect(t.run(), isTrue, reason: 'the other three finish the game');
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

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

  test('a lone person who leaves during the pass sees the bots play the game out, their own seat included', () {
    final t = SimTable(humans: 1, seed: 11, crypto: crypto, jurors: 2);
    t.people[0].exitAt = Moment.duringPass;
    t.people[0].exit = Exit.leave;
    t.start();
    // Nobody is left to finish for: the leaver's client looks on as
    // four bots play, its own seat's moves computed from the secret
    // it still holds, until the game ends.
    expect(t.clock.runUntil(() => t.clients.first.done, limitMs: 3 * 60 * 60 * 1000), isTrue);
    expect(t.people[0].gone, isTrue);
    expect(t.clients.first.pause, isNull);
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
      expect(t.run(), isTrue);
      expect(t.people[1].gone, isTrue, reason: 'the moment came');
      for (final c in t.survivors) {
        expect(c.game.knowsHand(1), isTrue);
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
