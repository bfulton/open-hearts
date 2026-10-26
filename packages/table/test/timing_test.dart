/// A table's own clocks (timing.dart): chosen by whoever starts the
/// table, carried in the start event, and the same at every seat and
/// juror — or, where the event says none or says one out of bounds,
/// the clocks every build reads that as ([TableTiming.unsaid]).
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// A spec as a seat reads it off the wire.
TableSpec overTheWire(TableSpec spec) => TableSpec.parse(jsonDecode(jsonEncode(spec.toJson())))!;

void main() {
  group('parse', () {
    test('the standard is today\'s clocks: a person silent half a minute is gone', () {
      const s = TableTiming.standard;
      expect(s.bank.graceMs, 6000);
      expect(s.bank.passGraceMs, 20000);
      expect(s.bank.bankMs, 45000);
      expect(s.bank.fixedMs, 40000);
      expect(s.botActsMs, 15000);
      expect(s.botDealsMs, 40000);
      expect(s.quorumLostMs, 20000);
      expect(s.silenceMs, 30000);
      expect(s.jurorSilenceMs, 30000);
      expect(TableTiming.bounds.keys, unorderedEquals(s.toJson().keys), reason: 'every field has bounds');
      for (final t in [s, TableTiming.unsaid]) {
        for (final MapEntry(:key, :value) in t.toJson().entries) {
          final (least, most) = TableTiming.bounds[key]!;
          expect(value, inInclusiveRange(least, most), reason: '$key is a timing a start may say: $t');
        }
      }
    });

    // What a start event that names no timing means, which every build
    // has to read alike: the first builds' standard, for good. A start
    // from one of them says none, and a juror reading it on this build
    // plays by the clocks its seats play by.
    test('none said is the first builds\' standard, whatever the standard is now', () {
      for (final none in [null, const <String, Object?>{}, 'fast', 42, const [6000]]) {
        expect(TableTiming.parse(none), TableTiming.unsaid, reason: '$none');
      }
      const u = TableTiming.unsaid;
      expect(u.bank.graceMs, 6000);
      expect(u.bank.passGraceMs, 20000);
      expect(u.bank.bankMs, 45000);
      expect(u.bank.fixedMs, 40000);
      expect(u.botActsMs, 15000);
      expect(u.botDealsMs, 40000);
      expect(u.quorumLostMs, 20000);
      expect(u.silenceMs, 120000);
      expect(u.jurorSilenceMs, 30000);
    });

    test('the operator\'s word is read over the standard, all or nothing as a start is', () {
      for (final none in [null, const <String, Object?>{}, 'fast', 42]) {
        expect(TableTiming.parse(none, base: TableTiming.standard), TableTiming.standard, reason: '$none');
      }
      final t = TableTiming.parse({'bankMs': 10000}, base: TableTiming.standard);
      expect(t.bank.bankMs, 10000);
      expect(t.silenceMs, TableTiming.standard.silenceMs, reason: 'a field not named is the standard\'s');
      expect(TableTiming.parse({'bankMs': 10000, 'silenceMs': 1}, base: TableTiming.standard), TableTiming.standard);
    });

    // A device whose way in has stalled knows it only once it has heard
    // nothing for unansweredMs (transport.dart); a juror judged by it
    // before then would be judged on a move it could not hear
    // (cut_off_test.dart). The standard gives every juror's clock longer.
    test('the standard gives a juror longer than a device takes to find its own line down', () {
      const s = TableTiming.standard;
      expect(s.botActsMs, greaterThan(unansweredMs));
      expect(s.jurorSilenceMs, greaterThan(unansweredMs));
    });

    test('the fields said are taken, the rest are what none said means', () {
      final t = TableTiming.parse({'graceMs': 3000, 'botActsMs': 8000, 'later': 'a later build\'s'});
      expect(t.bank.graceMs, 3000);
      expect(t.botActsMs, 8000);
      expect(t.bank.bankMs, 45000);
      expect(t.quorumLostMs, 20000);
      expect(t.silenceMs, TableTiming.unsaid.silenceMs);
      expect(TableTiming.parse(t.toJson()), t, reason: 'round trip');
      expect(TableTiming.parse(jsonDecode(jsonEncode(t.toJson()))), t, reason: 'and through JSON');
    });

    test('one field out of bounds, or of the wrong type, and the whole of it is what none said means', () {
      for (final MapEntry(:key, value: (least, most)) in TableTiming.bounds.entries) {
        expect(TableTiming.parse({key: least}).toJson()[key], least, reason: '$key at its least is in');
        expect(TableTiming.parse({key: most}).toJson()[key], most, reason: '$key at its most is in');
        for (final bad in [least - 1, most + 1, '$least', least.toDouble(), null, true]) {
          expect(TableTiming.parse({'graceMs': 3000, key: bad}), TableTiming.unsaid, reason: '$key: $bad');
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
        expect(TableTiming.parse({...said, 'bankMs': 5000}), TableTiming.unsaid);
      }
    });

    test('the spec carries it in full, and leaves out only what none said means', () {
      final seats = [const HumanSeat('a'), const HumanSeat('b'), BotSeat(Persona.roster[0]), BotSeat(Persona.roster[1])];
      final plain = TableSpec(id: 't', seed: 1, seats: seats);
      expect(plain.timing, TableTiming.standard);
      expect(plain.toJson()['timing'], TableTiming.standard.toJson(),
          reason: 'every field said, so a build with another standard reads the same clocks');
      expect(overTheWire(plain).timing, TableTiming.standard);
      final quick = TableSpec(id: 't', seed: 1, seats: seats, timing: TableTiming.parse({'graceMs': 3000}));
      expect(overTheWire(quick).timing, quick.timing);
      final first = TableSpec(id: 't', seed: 1, seats: seats, timing: TableTiming.unsaid);
      expect(first.toJson().containsKey('timing'), isFalse);
      expect(overTheWire(first).timing, TableTiming.unsaid);
      // A start event from a build with no timing to say, and one whose
      // timing is out of bounds: what none said means, at every seat
      // that reads it.
      final old = first.toJson();
      expect(TableSpec.parse(old)!.timing, TableTiming.unsaid);
      expect(TableSpec.parse({...old, 'timing': {'graceMs': 500}})!.timing, TableTiming.unsaid);
      expect(TableSpec.parse({...old, 'timing': 'quick'})!.timing, TableTiming.unsaid);
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

    test('a timing out of bounds is what none said means at every seat: the same player keeps five cards', () {
      final t = SimTable(humans: 4, seed: 71, timing: TableTiming.parse({'graceMs': 2000, 'bankMs': 1000}));
      expect(t.clients.every((c) => c.timing == TableTiming.unsaid), isTrue);
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
    setUpAll(() async => crypto = await rememberedCrypto());

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
