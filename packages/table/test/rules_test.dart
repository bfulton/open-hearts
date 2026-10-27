/// The rules a table's log is played by (rules.dart), fed entries by
/// hand: what is taken, from whom, and what the referee's clock does.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// A log being written for [rules]: each entry numbered and stamped.
class Writer {
  Writer(this.rules, {this.t = 1000000});
  final TableRules rules;
  int t;
  int _n = 0;

  void event(TableEvent e, {int after = 10}) => _add(event: e, after: after);
  void tick({int after = 10}) => _add(after: after);
  void up(PublicKey k, {int after = 10}) => _add(up: k, after: after);
  void down(PublicKey k, {int after = 10}) => _add(down: k, after: after);

  void _add({TableEvent? event, PublicKey? up, PublicKey? down, required int after}) {
    t += after;
    rules.feed(LogEntry(n: _n++, t: t, event: event, up: up, down: down));
  }
}

final p0 = FakeSigner('rules p0');
final p1 = FakeSigner('rules p1');
final stranger = FakeSigner('rules stranger');

TableSpec specOf({String id = 'rules-table', TableTiming timing = TableTiming.standard}) => TableSpec(
      id: id,
      seed: 9,
      seats: [HumanSeat(p0.publicKey), HumanSeat(p1.publicKey), BotSeat(Persona.roster[0]), BotSeat(Persona.roster[1])],
      sealed: false,
      timing: timing,
    );

TableEvent ev(Signer s, EventKind kind, Map<String, Object?> body, {String table = 'rules-table'}) =>
    TableEvent.sign(s, table: table, kind: kind, body: body);

TableEvent start(Signer s, TableSpec spec) => ev(s, EventKind.start, {'spec': spec.toJson()}, table: spec.id);

TableEvent passOf(Signer s, TableRules r, int seat, {List<Card>? cards, int? turn}) => ev(s, EventKind.pass, {
      'hand': r.game.handNumber,
      'turn': turn ?? TurnId.pass(r.game.handNumber, seat).index,
      'seat': seat,
      'cards': [for (final c in cards ?? r.game.handOf(seat).take(passSize)) c.code],
    });

/// A table started, both people's passes open.
(TableRules, Writer) started({TableTiming timing = TableTiming.standard}) {
  final r = TableRules(tableId: 'rules-table');
  final w = Writer(r)..event(start(p0, specOf(timing: timing)));
  return (r, w);
}

void main() {
  group('the start', () {
    test('starts the table its spec names, said by a person seated at it', () {
      final (r, _) = started();
      expect(r.state, TableState.playing);
      expect([for (final h in r.holders) h is HumanSeat ? h.key : (h as BotSeat).persona.name],
          [p0.publicKey, p1.publicKey, Persona.roster[0].name, Persona.roster[1].name]);
      expect(r.game.phase, Phase.passing);
      expect(r.owed.keys, unorderedEquals([0, 1]), reason: 'the people\'s passes; the bots\' are worked out');
    });

    for (final (what, entry) in [
      ('another table', start(p0, specOf(id: 'elsewhere'))),
      ('a key nobody seated', start(stranger, specOf())),
      ('no start at all', ev(p0, EventKind.leave, {'seat': 0})),
    ]) {
      test('fails for $what', () {
        final r = TableRules(tableId: 'rules-table');
        Writer(r).event(entry);
        expect(r.state, TableState.failed);
        expect(r.over, isTrue);
      });
    }

    test('fails a sealed table without a house', () {
      final spec = TableSpec(id: 'rules-table', seed: 9, seats: specOf().seats, sealed: true);
      final r = TableRules(tableId: 'rules-table');
      Writer(r).event(start(p0, spec));
      expect(r.state, TableState.failed);
    });
  });

  group('a move', () {
    test('is taken from the seat\'s own person, for the turn open', () {
      final (r, w) = started();
      w.event(passOf(p0, r, 0));
      expect(r.game.hasPassed(0), isTrue);
      expect(r.owed.keys, [1]);
    });

    test('is not taken from anyone else, for another turn, or with cards the seat does not hold', () {
      final (r, w) = started();
      final notMine = r.game.handOf(1).take(passSize).toList();
      for (final e in [
        passOf(p1, r, 0), // signed by the other person
        passOf(stranger, r, 0), // by a key not at the table
        passOf(p0, r, 0, turn: TurnId.pass(0, 1).index), // the turn another seat owes
        passOf(p0, r, 0, cards: notMine), // cards from another hand
        passOf(p0, r, 0, cards: [r.game.handOf(0).first, r.game.handOf(0).first, r.game.handOf(0).first]),
        passOf(p0, r, 2), // a bot seat, which nobody here says anything for
      ]) {
        w.event(e);
      }
      for (var s = 0; s < 2; s++) {
        expect(r.game.hasPassed(s), isFalse, reason: 'seat $s');
      }
      expect(r.taken, isEmpty);
      // And the turn is still open to the one it is owed to.
      w.event(passOf(p0, r, 0));
      expect(r.game.hasPassed(0), isTrue);
    });

    test('a play out of turn is not taken', () {
      final (r, w) = started();
      w
        ..event(passOf(p0, r, 0))
        ..event(passOf(p1, r, 1));
      expect(r.game.phase, Phase.playing);
      final onPlay = r.game.currentSeat!;
      // The person not on play plays a card of their own.
      final other = onPlay == 0 ? 1 : 0;
      final otherSigner = other == 0 ? p0 : p1;
      final before = r.moves.length;
      w.event(ev(otherSigner, EventKind.play, {
        'hand': 0,
        'turn': TurnId.play(0, r.game.tricksPlayed * seatCount + r.game.trick.length).index,
        'seat': other,
        'card': r.game.handOf(other).first.code,
      }));
      expect(r.moves.length, before);
    });
  });

  group('a leave', () {
    test('removes its author at once, and nobody else', () {
      final (r, w) = started();
      w.event(ev(p1, EventKind.leave, {'seat': 0}));
      expect(r.removals, isEmpty, reason: 'nobody leaves for somebody else');
      w.event(ev(p0, EventKind.leave, {'seat': 0}));
      expect(r.removals[0]!.exit, Exit.left);
      expect(r.holders[0], isA<BotSeat>());
      expect(r.state, TableState.playing);
      w.event(ev(p1, EventKind.leave, {'seat': 1}));
      expect(r.state, TableState.ended, reason: 'nobody is left');
    });
  });

  group('the clock', () {
    test('a turn past its deadline loses the seat; one taken in its grace costs the bank nothing', () {
      final (r, w) = started();
      final bank = r.timing.bank;
      final deadline = r.owed[1]!.deadline;
      w.event(passOf(p0, r, 0), after: bank.passGraceMs - 10);
      expect(r.banks[0], bank.bankMs, reason: 'inside the grace');
      w.t = deadline - 10;
      w.tick(after: 0);
      expect(r.removals, isEmpty, reason: 'not yet');
      w.tick(after: 11);
      expect(r.removals[1]!.exit, Exit.booted);
      expect(r.holders[1], isA<BotSeat>());
    });

    test('time past the grace comes off the bank', () {
      final (r, w) = started();
      final bank = r.timing.bank;
      w.event(passOf(p0, r, 0), after: bank.passGraceMs + 7000);
      expect(r.banks[0], bank.bankMs - 7000);
    });

    test('a connection closed for the silence at its turn loses the seat, without waiting on the clock', () {
      final (r, w) = started();
      final silence = r.timing.silenceMs;
      w.down(p1.publicKey);
      final went = w.t;
      w.t = went + silence - 1;
      w.tick(after: 0);
      expect(r.removals, isEmpty);
      w.tick(after: 1);
      expect(r.removals[1]!.exit, Exit.absent);
      expect(w.t, lessThan(r.log.first.t + r.timing.bank.passGraceMs + r.timing.bank.bankMs), reason: 'well before the clock');
    });

    test('a connection back before the silence keeps the seat', () {
      final (r, w) = started();
      final silence = r.timing.silenceMs;
      w.down(p1.publicKey);
      w.up(p1.publicKey, after: silence - 100);
      w.tick(after: 200);
      expect(r.removals, isEmpty);
      expect(r.down, isEmpty);
    });

    test('a closed connection is only counted at its own turn', () {
      final (r, w) = started();
      w.event(passOf(p1, r, 1));
      w.down(p1.publicKey);
      w.tick(after: r.timing.silenceMs + 10);
      expect(r.removals, isEmpty, reason: 'seat 1 owes nothing now');
    });
  });

  group('sealed', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    test('a side with no seat, replaying the log, comes to the same end; only the house\'s true word on it is kept', () {
      final t = SimTable(humans: 2, seed: 71, crypto: crypto);
      t.start();
      expect(t.run(), isTrue);
      final seated = t.clients.first.rules;
      final endN = seated.endN!;
      // Anyone at all, with the log: no key, no seat, nothing to open.
      final v = TableRules(tableId: t.spec.id, crypto: crypto);
      for (final e in t.referee.log.take(endN)) {
        v.feed(e);
      }
      expect(v.state, TableState.finished);
      expect(v.endN, endN);
      expect(v.endHash, seated.endHash);
      expect(v.game.totals, seated.game.totals);
      final truth = seated.result!;
      var n = endN;
      var at = t.referee.log[endN - 1].t;
      void feed(TableEvent e) => v.feed(LogEntry(n: n++, t: at += 10, event: e));
      Map<String, Object?> body([Map<String, Object?> change = const {}]) => {...truth.body, ...change};
      final house = t.houseSigner;
      for (final forged in [
        ev(p0, EventKind.result, body(), table: t.spec.id), // not the house
        ev(house, EventKind.result, body({'n': endN - 1}), table: t.spec.id),
        ev(house, EventKind.result, body({'hash': seated.log.first.event!.id}), table: t.spec.id),
        ev(house, EventKind.result, body({'state': TableState.ended.name}), table: t.spec.id),
        ev(house, EventKind.result, body({'totals': [0, 0, 0, 0]}), table: t.spec.id),
      ]) {
        feed(forged);
        expect(v.result, isNull, reason: '${forged.author == house.publicKey ? 'the house' : 'a person'}: ${forged.body}');
      }
      feed(truth);
      expect(v.result?.id, truth.id);
    });
  });
}
