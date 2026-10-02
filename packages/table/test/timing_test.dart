/// A table's own clocks (timing.dart): chosen by whoever starts the
/// table, carried in the start event, and the same at every seat and
/// juror — or the standard, where the event says none or says one out
/// of bounds.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

/// A spec as a seat reads it off the wire.
TableSpec overTheWire(TableSpec spec) => TableSpec.parse(jsonDecode(jsonEncode(spec.toJson())))!;

void main() {
  group('parse', () {
    test('none said is the standard table, and the standard is today\'s clocks', () {
      for (final none in [null, const <String, Object?>{}, 'fast', 42, const [6000]]) {
        expect(TableTiming.parse(none), TableTiming.standard, reason: '$none');
      }
      const s = TableTiming.standard;
      expect(s.bank.graceMs, 6000);
      expect(s.bank.passGraceMs, 20000);
      expect(s.bank.bankMs, 45000);
      expect(s.bank.fixedMs, 40000);
      expect(s.botActsMs, 15000);
      expect(s.botDealsMs, 40000);
      expect(s.quorumLostMs, 20000);
      expect(s.silenceMs, 120000);
      expect(s.jurorSilenceMs, 30000);
      expect(TableTiming.bounds.keys, unorderedEquals(s.toJson().keys), reason: 'every field has bounds');
      for (final MapEntry(:key, :value) in s.toJson().entries) {
        final (least, most) = TableTiming.bounds[key]!;
        expect(value, inInclusiveRange(least, most), reason: 'the standard $key is a timing a start may say');
      }
    });

    test('the fields said are taken, the rest are the standard', () {
      final t = TableTiming.parse({'graceMs': 3000, 'botActsMs': 8000, 'later': 'a later build\'s'});
      expect(t.bank.graceMs, 3000);
      expect(t.botActsMs, 8000);
      expect(t.bank.bankMs, 45000);
      expect(t.quorumLostMs, 20000);
      expect(TableTiming.parse(t.toJson()), t, reason: 'round trip');
      expect(TableTiming.parse(jsonDecode(jsonEncode(t.toJson()))), t, reason: 'and through JSON');
    });

    test('one field out of bounds, or of the wrong type, and the whole of it is the standard', () {
      for (final MapEntry(:key, value: (least, most)) in TableTiming.bounds.entries) {
        expect(TableTiming.parse({key: least}).toJson()[key], least, reason: '$key at its least is in');
        expect(TableTiming.parse({key: most}).toJson()[key], most, reason: '$key at its most is in');
        for (final bad in [least - 1, most + 1, '$least', least.toDouble(), null, true]) {
          expect(TableTiming.parse({'graceMs': 3000, key: bad}), TableTiming.standard, reason: '$key: $bad');
        }
      }
      expect(TableTiming.parse({'graceMs': 3000, 'jurorsWaitMs': 40000}).bank.graceMs, 3000,
          reason: 'the jury waits an older build said are passed over, not refused');
    });

    test('a function of what it is given: the same event is the same clocks, however often it is read', () {
      final said = {'graceMs': 4000, 'passGraceMs': 15000, 'bankMs': 60000, 'silenceMs': 90000};
      final first = TableTiming.parse(said);
      for (var i = 0; i < 20; i++) {
        expect(TableTiming.parse(jsonDecode(jsonEncode(said))), first);
        expect(TableTiming.parse({...said, 'bankMs': 5000}), TableTiming.standard);
      }
    });

    test('the spec carries it; an ordinary table\'s spec reads as it always did', () {
      final seats = [const HumanSeat('a'), const HumanSeat('b'), BotSeat(Persona.roster[0]), BotSeat(Persona.roster[1])];
      final plain = TableSpec(id: 't', seed: 1, seats: seats);
      expect(plain.toJson().containsKey('timing'), isFalse);
      expect(overTheWire(plain).timing, TableTiming.standard);
      final quick = TableSpec(id: 't', seed: 1, seats: seats, timing: TableTiming.parse({'graceMs': 3000}));
      expect(overTheWire(quick).timing, quick.timing);
      // A start event from a build with no timing, and one whose timing
      // is out of bounds: the standard, at every seat that reads it.
      final old = plain.toJson();
      expect(TableSpec.parse(old)!.timing, TableTiming.standard);
      expect(TableSpec.parse({...old, 'timing': {'graceMs': 500}})!.timing, TableTiming.standard);
      expect(TableSpec.parse({...old, 'timing': 'quick'})!.timing, TableTiming.standard);
    });
  });

  group('at the table', () {
    // Two seconds' grace and ten of bank: fourteen seconds over a card
    // is past the first card's allowance, where the standard's fifty-one
    // would have let five go (time_bank_test.dart).
    final quick = TableTiming.parse({'graceMs': 2000, 'bankMs': 10000});

    test('a shorter clock boots sooner, at every seat alike', () {
      final t = SimTable(humans: 4, seed: 71, timing: quick);
      expect(t.clients.every((c) => c.timing == quick), isTrue);
      t.people[1].thinkMs = 14000;
      t.start();
      final c = t.people[0].client;
      expect(t.clock.runUntil(() => c.game.handNumber > 0 || c.done, limitMs: 10 * 60 * 1000), isTrue);
      for (final p in [t.people[0], t.people[2], t.people[3]]) {
        final booted = p.client.record.where((d) => d.removal && d.event.seat == 1).toList();
        expect(booted, hasLength(1), reason: 'booted at every seat');
        expect(booted.single.turn.hand, 0);
        expect(p.client.record.where((d) => d.turn.isPlay && d.event.seat == 1 && !d.removal), isEmpty,
            reason: 'on its first card, not its sixth');
        expect(p.client.record.map((d) => d.key), c.record.map((d) => d.key), reason: 'one record');
      }
      t.stop();
    });

    test('a timing out of bounds is the standard at every seat: the same player keeps five cards', () {
      final t = SimTable(humans: 4, seed: 71, timing: TableTiming.parse({'graceMs': 2000, 'bankMs': 1000}));
      expect(t.clients.every((c) => c.timing == TableTiming.standard), isTrue);
      t.people[1].thinkMs = 14000;
      t.start();
      final c = t.people[0].client;
      expect(t.clock.runUntil(() => c.record.any((d) => d.removal), limitMs: 10 * 60 * 1000), isTrue);
      expect(c.record.where((d) => d.turn.hand == 0 && d.turn.isPlay && d.event.seat == 1 && !d.removal).length, 5);
      t.stop();
    });
  });

  group('sealed, with a jury', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await DealCrypto.load());

    test('the jurors play by the starter\'s clocks too: a held seat gone idle goes to the escrow at its five seconds', () {
      final fast = TableTiming.parse({'botActsMs': 5000});
      final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, timing: fast);
      t.start();
      expect(t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue,
          reason: 'the hand was dealt');
      final summoned = [for (final j in t.jurors) if (j.client != null) j.client!];
      expect(summoned, isNotEmpty);
      for (final j in summoned) {
        expect(j.timing, fast, reason: 'a juror reads the table\'s timing from its summons');
      }
      final c = t.clients.first;
      final hand = c.game.handNumber;
      final seat = c.botHolders(hand).keys.first;
      t.net.doze(c.botHolders(hand)[seat]!);
      // Well inside the standard's fifteen seconds from the seat's turn
      // opening: only the table's five can have done it.
      expect(t.clock.runUntil(() => c.deal!.gone.contains(seat), limitMs: 12000), isTrue,
          reason: 'the seat went to the escrow by the table\'s clock:\n${c.describe()}');
      expect(t.clock.runUntil(() => c.game.handNumber > hand, limitMs: 5 * 60 * 1000), isTrue,
          reason: 'and the hand was played out: ${c.describe()}');
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
