/// The departure matrix from docs/06-service.md, run on the simulator.
///
/// Every cell plays a whole game with some of its humans leaving the
/// way and at the moment the cell says, then checks what every cell
/// must satisfy: the survivors agree on one record, the record
/// verifies, departed seats are bots, ratings follow the two rules,
/// and the table either finishes or pauses for a reason it can name.
library;

import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';


/// What the participant arithmetic says a cell should do: a removal
/// carries when the survivors are a strict majority of the set it is
/// decided against; a signed leave always carries.
bool expectFinish(int humans, List<(Exit, bool sameWindow)> departures) {
  var n = humans;
  var i = 0;
  while (i < departures.length) {
    final (exit, same) = departures[i];
    final batch = same ? 2 : 1;
    if (exit == Exit.leave) {
      n -= batch;
    } else {
      if (n - batch < n ~/ 2 + 1) return false;
      n -= batch;
    }
    i += batch;
  }
  return true;
}

void checkAgreement(SimTable t, {required Iterable<TableClient> among}) {
  final records = [for (final c in among) c.record.map((d) => d.key).toList()];
  for (final r in records) {
    expect(r, records.first, reason: 'every survivor holds the same record');
  }
  final totals = [for (final c in among) c.game.totals];
  for (final s in totals) {
    expect(s, totals.first, reason: 'every survivor has the same scores');
  }
}

void checkFinished(SimTable t, {required Set<int> departedSeats}) {
  final survivors = t.survivors.toList();
  expect(survivors, isNotEmpty);
  for (final c in survivors) {
    expect(c.done, isTrue, reason: 'the game reaches its end');
    expect(c.pause, isNull);
    for (final s in departedSeats) {
      expect(c.holders[s], isA<BotSeat>(), reason: 'seat $s is a bot');
    }
  }
  checkAgreement(t, among: survivors);
  final v = verifyRecord(t.spec, survivors.first.record, juries: survivors.first.juries);
  expect(v.ok, isTrue, reason: v.reason);
  expect(v.winners, survivors.first.game.winners);
  for (final s in departedSeats) {
    expect(v.finalHolders[s], isA<BotSeat>());
  }
  // Ratings: a bot in a winning seat moves nobody; a live winner moves
  // everyone, leavers included.
  final botWon = v.winners.any((s) => v.finalHolders[s] is BotSeat);
  for (var s = 0; s < t.humans; s++) {
    final key = t.signers[s].publicKey;
    expect(v.ratings.containsKey(key), isTrue, reason: 'everyone who sat is rated');
    if (botWon) {
      expect(v.ratings[key], 0);
    } else {
      expect(v.ratings[key], v.winners.contains(s) ? 1 : -1);
    }
  }
}

void checkPaused(SimTable t) {
  final survivors = t.survivors.toList();
  expect(survivors, isNotEmpty);
  for (final c in survivors) {
    expect(c.done, isFalse);
    expect(c.pause, isNotNull, reason: 'a table that cannot go on says why');
  }
  checkAgreement(t, among: survivors);
}

void main() {
  group('one player goes', () {
    for (final humans in [2, 3, 4]) {
      for (final exit in Exit.values) {
        for (final moment in Moment.all) {
          final finish = expectFinish(humans, [(exit, false)]);
          test('$humans humans, seat 0 ${exit.name}s $moment → ${finish ? 'finishes' : 'pauses'}', () {
            final t = SimTable(humans: humans, seed: 11 + humans);
            t.people[0]
              ..exit = exit
              ..exitAt = moment;
            t.start();
            t.run();
            expect(t.people[0].gone, isTrue, reason: 'the moment came');
            if (finish) {
              checkFinished(t, departedSeats: {0});
            } else {
              checkPaused(t);
            }
            t.stop();
          });
        }
      }
    }
  });

  group('two players go', () {
    for (final humans in [3, 4]) {
      for (final exit in Exit.values) {
        final together = expectFinish(humans, [(exit, true), (exit, true)]);
        test('$humans humans, seats 0 and 1 ${exit.name} in the same window → ${together ? 'finishes' : 'pauses'}', () {
          final t = SimTable(humans: humans, seed: 21 + humans);
          for (final i in [0, 1]) {
            t.people[i]
              ..exit = exit
              ..exitAt = Moment.handBoundary;
          }
          t.start();
          t.run();
          expect(t.people[0].gone && t.people[1].gone, isTrue);
          if (together) {
            checkFinished(t, departedSeats: {0, 1});
          } else {
            checkPaused(t);
          }
          t.stop();
        });

        final inTurn = expectFinish(humans, [(exit, false), (exit, false)]);
        test('$humans humans, seat 0 ${exit.name}s in hand 1 and seat 1 in hand 2 → ${inTurn ? 'finishes' : 'pauses'}', () {
          final t = SimTable(humans: humans, seed: 31 + humans);
          t.people[0]
            ..exit = exit
            ..exitAt = Moment.onOwnTurn;
          t.people[1]
            ..exit = exit
            ..exitAt = Moment('on own turn, hand 2', Moment.onOwnTurn.holds, fromHand: 2);
          t.start();
          t.run();
          expect(t.people[0].gone, isTrue);
          if (inTurn) {
            expect(t.people[1].gone, isTrue);
            checkFinished(t, departedSeats: {0, 1});
          } else {
            checkPaused(t);
          }
          t.stop();
        });
      }
    }
  });

  group('the boot clock', () {
    test('a card at 50.9 seconds, the bank all but spent, beats a boot at 51.0', () {
      final t = SimTable(humans: 3, seed: 41);
      // Seat 0 passes quickly, then dawdles over its first card until a
      // tenth of a second of its bank is left — the others press the
      // moment the button appears — and plays every card after within
      // the grace, which costs nothing.
      final slow = ScriptedHuman(t.people[0].client, t.net, t.clock, persona: Persona.westley, thinkMs: 1000);
      slow.client.changes.listen((_) {
        final c = slow.client;
        if (c.game.phase == Phase.passing) {
          slow.thinkMs = 1000;
        } else {
          slow.thinkMs = c.record.any((d) => d.turn.isPlay && d.event.seat == 0 && !d.removal) ? 5900 : 50900;
        }
      });
      t.people[0].stop();
      t.people[0] = slow;
      t.start();
      expect(t.run(), isTrue);
      checkFinished(t, departedSeats: {});
      expect(t.clients.first.holders[0], isA<HumanSeat>(), reason: 'seat 0 was never booted');
      expect(t.clients.first.record.where((d) => d.removal), isEmpty);
      t.stop();
    });

    test('a play after the boot has carried does not count', () {
      final t = SimTable(humans: 3, seed: 42);
      final late = ScriptedHuman(t.people[0].client, t.net, t.clock, persona: Persona.westley, thinkMs: 16500);
      t.people[0].stop();
      t.people[0] = late;
      t.start();
      expect(t.run(), isTrue);
      final survivors = [t.people[1].client, t.people[2].client];
      checkAgreement(t, among: survivors);
      for (final c in survivors) {
        expect(c.holders[0], isA<BotSeat>(), reason: 'seat 0 was booted');
        expect(c.done, isTrue);
      }
      final v = verifyRecord(t.spec, survivors.first.record, juries: survivors.first.juries);
      expect(v.ok, isTrue, reason: v.reason);
      expect(survivors.first.record.where((d) => d.removal && d.event.kind == EventKind.boot), isNotEmpty);
      t.stop();
    });
  });

  group('partitions', () {
    test('four humans split two and two: nobody is removed, and the game finishes when it heals', () {
      final t = SimTable(humans: 4, seed: 51);
      final keys = t.signers.map((s) => s.publicKey).toList();
      t.start();
      // Let a hand get under way, then split for a minute.
      t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 3600000);
      t.net.partition([
        {keys[0], keys[1]},
        {keys[2], keys[3]},
      ]);
      t.clock.advance(60000);
      for (final c in t.clients) {
        expect(c.participants.length, 4, reason: 'no side can carry a removal');
        expect(c.done, isFalse);
      }
      t.net.heal();
      expect(t.run(), isTrue, reason: 'healed, the table finishes');
      checkFinished(t, departedSeats: {});
      t.stop();
    });

    test('a seat that only one peer hears directly is carried, not booted', () {
      // Two links dead both ways without anyone noticing: seat 1 reaches
      // seat 0 alone. Seats 2 and 3 get seat 1's plays only as seat 0
      // relays them — which once counted as no hearing at all, so at
      // seat 1's turn they booted it while seat 0 witnessed its play,
      // two against two, and the table split for the jury. Fresh work
      // by a seat, however it arrives, is the seat.
      final t = SimTable(humans: 4, seed: 53);
      final keys = t.signers.map((s) => s.publicKey).toList();
      t.start();
      t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 3600000);
      t.net.cut(keys[1], keys[2]);
      t.net.cut(keys[1], keys[3]);
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 4 * 3600000), isTrue,
          reason: 'the table finishes with every seat carried');
      for (final c in t.clients) {
        expect(c.participants.length, 4, reason: 'nobody was removed');
      }
      checkFinished(t, departedSeats: {});
      t.stop();
    });

    test('three humans split two and one: the majority carries on, the one is out', () {
      final t = SimTable(humans: 3, seed: 52);
      final keys = t.signers.map((s) => s.publicKey).toList();
      t.start();
      t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 3600000);
      t.net.partition([
        {keys[0], keys[1]},
        {keys[2]},
      ]);
      final majority = [t.people[0].client, t.people[1].client];
      expect(t.clock.runUntil(() => majority.every((c) => c.done), limitMs: 3600000), isTrue);
      checkAgreement(t, among: majority);
      for (final c in majority) {
        expect(c.holders[2], isA<BotSeat>());
      }
      final v = verifyRecord(t.spec, majority.first.record, juries: majority.first.juries);
      expect(v.ok, isTrue, reason: v.reason);
      final alone = t.people[2].client;
      expect(alone.done, isFalse);
      expect(alone.pause, isNotNull, reason: 'the one on its own knows it is stuck');
      t.stop();
    });
  });
}
