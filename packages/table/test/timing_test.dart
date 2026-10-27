/// A table's own clocks (timing.dart): chosen by whoever starts the
/// table, carried in full in the log's start, and the same at every
/// side — or no table at all.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// A spec as a side reads it off the log.
TableSpec? overTheWire(TableSpec spec) => TableSpec.parse(jsonDecode(jsonEncode(spec.toJson())));

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
      expect(s.houseGraceMs, 20000);
      expect(s.silenceMs, 30000);
      expect(TableTiming.bounds.keys, unorderedEquals(s.toJson().keys), reason: 'every field has bounds');
      for (final MapEntry(:key, :value) in s.toJson().entries) {
        final (least, most) = TableTiming.bounds[key]!;
        expect(value, inInclusiveRange(least, most), reason: '$key is a timing a start may say');
      }
    });

    test('the operator\'s word is read over the standard, all or nothing', () {
      for (final none in [null, const <String, Object?>{}, 'fast', 42]) {
        expect(TableTiming.parse(none), TableTiming.standard, reason: '$none');
      }
      final t = TableTiming.parse({'bankMs': 10000, 'later': 'a later build\'s'});
      expect(t.bank.bankMs, 10000);
      expect(t.silenceMs, TableTiming.standard.silenceMs, reason: 'a field not named is the standard\'s');
      expect(TableTiming.parse({'bankMs': 10000, 'silenceMs': 1}), TableTiming.standard);
      expect(TableTiming.parse(jsonDecode(jsonEncode(t.toJson()))), t, reason: 'round trip through JSON');
    });

    test('one field out of bounds, or of the wrong type, and the whole of it is the standard', () {
      for (final MapEntry(:key, value: (least, most)) in TableTiming.bounds.entries) {
        expect(TableTiming.parse({key: least}).toJson()[key], least, reason: '$key at its least is in');
        expect(TableTiming.parse({key: most}).toJson()[key], most, reason: '$key at its most is in');
        for (final bad in [least - 1, most + 1, '$least', least.toDouble(), null, true]) {
          expect(TableTiming.parse({'graceMs': 3000, key: bad}), TableTiming.standard, reason: '$key: $bad');
        }
      }
    });

    // A start is read by every side, of whatever build, and has to be
    // the same clocks at each: nothing filled in from a standard another
    // build may have changed, and nothing a build does not know.
    test('a start\'s timing is taken only in full', () {
      final full = TableTiming.parse({'graceMs': 3000}).toJson();
      expect(TableTiming.exactly(full)?.bank.graceMs, 3000);
      expect(TableTiming.exactly(jsonDecode(jsonEncode(full))), TableTiming.parse(full));
      for (final key in full.keys) {
        expect(TableTiming.exactly({...full}..remove(key)), isNull, reason: 'without $key');
        final (least, most) = TableTiming.bounds[key]!;
        expect(TableTiming.exactly({...full, key: most + 1}), isNull, reason: '$key out of bounds');
        expect(TableTiming.exactly({...full, key: '$least'}), isNull, reason: '$key a string');
      }
      expect(TableTiming.exactly({...full, 'later': 1}), isNull, reason: 'a clock this build cannot keep');
      for (final none in [null, const <String, Object?>{}, 'fast', 42]) {
        expect(TableTiming.exactly(none), isNull, reason: '$none');
      }
    });

    test('the spec carries it in full, and one without it is no spec', () {
      final seats = [const HumanSeat('a'), const HumanSeat('b'), BotSeat(Persona.roster[0]), BotSeat(Persona.roster[1])];
      final plain = TableSpec(seed: 1, seats: seats);
      expect(plain.toJson()['timing'], TableTiming.standard.toJson());
      expect(overTheWire(plain)!.timing, TableTiming.standard);
      final quick = TableSpec(seed: 1, seats: seats, timing: TableTiming.parse({'graceMs': 3000}));
      expect(overTheWire(quick)!.timing, quick.timing);
      final json = plain.toJson();
      expect(TableSpec.parse({...json}..remove('timing')), isNull);
      expect(TableSpec.parse({...json, 'timing': {'graceMs': 3000}}), isNull);
      expect(TableSpec.parse({...json, 'timing': 'quick'}), isNull);
    });
  });

  group('at the table', () {
    // Two seconds' grace and ten of bank: fourteen seconds over a card
    // is past the first card's allowance, where the standard's fifty-one
    // would have let five go (time_bank_test.dart).
    final quick = TableTiming.parse({'graceMs': 2000, 'bankMs': 10000});

    test('a shorter clock boots sooner, at every side alike', () {
      final t = SimTable(humans: 4, seed: 71, timing: quick);
      t.people[1].thinkMs = 14000;
      t.start();
      final c = t.people[0].client;
      expect(t.clock.runUntil(() => c.started && c.rules.removals.isNotEmpty, limitMs: 10 * 60 * 1000), isTrue);
      expect(c.rules.timing, quick);
      final r = c.rules.removals[1]!;
      expect(r.exit, Exit.booted);
      expect(r.hand, 0);
      expect(c.rules.taken.where((e) => e.kind == EventKind.play && e.seat == 1), isEmpty, reason: 'on its first card, not its sixth');
      expect(t.run(), isTrue);
      for (final p in t.people) {
        expect(p.client.rules.endHash, c.rules.endHash, reason: 'one log, one end');
        expect(p.client.rules.removals.keys, [1]);
      }
      t.close();
    });
  });

  group('sealed', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    test('the house plays by the starter\'s clocks too: gone, it fails the table at its five seconds and grace', () {
      final fast = TableTiming.parse({'botActsMs': 5000, 'houseGraceMs': 10000});
      final t = SimTable(humans: 2, seed: 3, crypto: crypto, timing: fast);
      t.start();
      final c = t.clients.first;
      bool houseOnPlay() => c.started && c.game.phase == Phase.playing && c.rules.owed.values.any((o) => o.actor == t.houseSigner.publicKey);
      expect(t.clock.runUntil(houseOnPlay, limitMs: 5 * 60 * 1000), isTrue, reason: 'a bot seat on play');
      // Gone the moment its seat's turn opened, before it can answer.
      final open = c.rules.owed.values.firstWhere((o) => o.actor == t.houseSigner.publicKey);
      t.killHouse();
      expect(t.run(), isTrue);
      expect(c.state, TableState.failed);
      expect(c.rules.now - open.since, inInclusiveRange(15000, 15000 + 1500),
          reason: 'its five seconds and its grace, and not the standard\'s thirty-five');
    });
  });
}
