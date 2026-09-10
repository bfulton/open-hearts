/// Random walks through the departure matrix.
///
/// The matrix enumerates the cases someone thought of. This drives the
/// simulator through faults nobody chose — departures, partitions,
/// loss and latency at random times — and checks, every few seconds of
/// virtual time, the invariants that must hold whatever happens:
/// survivors never hold conflicting decisions, every record verifies as
/// far as it goes, and every observed state change is one the model in
/// model.dart allows. Once the faults stop and the network heals, the
/// table finishes or is paused for the one reason the protocol admits
/// in this version.
library;

import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

/// Transitive closure of a transition relation, so a state sampled
/// after several steps is still checked against the model.
Map<T, Set<T>> closure<T>(Map<T, Set<T>> direct) {
  final out = {for (final e in direct.entries) e.key: Set.of(e.value)};
  var changed = true;
  while (changed) {
    changed = false;
    for (final from in out.keys) {
      for (final mid in List.of(out[from]!)) {
        for (final to in out[mid]!) {
          if (out[from]!.add(to)) changed = true;
        }
      }
    }
  }
  return out;
}

final turnClosure = closure(turnTransitions);
final seatClosure = closure(seatTransitions);
final tableClosure = closure(tableTransitions);

/// Two records conflict when they settle the same turn differently: two
/// different actions, or an action by a seat one record says was
/// removed at that very turn.
String? conflict(List<Decision> a, List<Decision> b) {
  final actionsA = {for (final d in a) if (!d.removal) d.turn: d};
  final actionsB = {for (final d in b) if (!d.removal) d.turn: d};
  for (final t in actionsA.keys) {
    final x = actionsA[t]!;
    final y = actionsB[t];
    if (y != null && x.key != y.key) return 'two actions at $t: ${x.event} vs ${y.event}';
  }
  bool removedAt(List<Decision> r, TurnId t, int seat) =>
      r.any((d) => d.removal && d.turn == t && d.event.seat == seat);
  for (final d in a) {
    if (d.removal) continue;
    if (removedAt(b, d.turn, d.event.seat)) return 'action by seat ${d.event.seat} at ${d.turn} vs its removal there';
  }
  for (final d in b) {
    if (d.removal) continue;
    if (removedAt(a, d.turn, d.event.seat)) return 'action by seat ${d.event.seat} at ${d.turn} vs its removal there';
  }
  return null;
}

class Observed {
  final Map<TurnId, TurnState> turns = {};
  final Map<int, SeatState> seats = {};
  TableState? table;
}

void main() {
  final seeds = int.parse(const String.fromEnvironment('CHAOS_SEEDS', defaultValue: '40'));

  for (var seed = 0; seed < seeds; seed++) {
    test('chaos $seed', () {
      final sc = ChaosScenario(seed);
      final t = sc.table;
      final observed = {for (final c in t.clients) c: Observed()};

      void check(String when) {
        final survivors = t.survivors.toList();
        for (var i = 0; i < survivors.length; i++) {
          for (var j = i + 1; j < survivors.length; j++) {
            final why = conflict(survivors[i].record, survivors[j].record);
            expect(why, isNull, reason: '$when: a fork between two survivors: $why');
          }
        }
        for (final c in survivors) {
          final v = verifyRecord(t.spec, c.record, allowPartial: true);
          expect(v.ok, isTrue, reason: '$when: ${c.signer.publicKey.substring(0, 6)} record: ${v.reason}');
        }
        for (final c in t.clients) {
          final o = observed[c]!;
          for (final e in c.turnStates.entries) {
            final before = o.turns[e.key];
            if (before != null && before != e.value) {
              expect(turnClosure[before]!.contains(e.value), isTrue,
                  reason: '$when: turn ${e.key} went $before → ${e.value}');
            }
            o.turns[e.key] = e.value;
          }
          for (var s = 0; s < seatCount; s++) {
            final now = c.seatStateOf(s);
            final before = o.seats[s];
            if (before != null && before != now) {
              expect(seatClosure[before]!.contains(now), isTrue, reason: '$when: seat $s went $before → $now');
            }
            o.seats[s] = now;
          }
          final now = c.tableState;
          final before = o.table;
          if (before != null && before != now) {
            expect(tableClosure[before]!.contains(now), isTrue, reason: '$when: table went $before → $now');
          }
          o.table = now;
        }
      }

      t.start();
      sc.schedule();
      var next = 5000;
      while (t.clock.nowMs < sc.quietAt && !t.survivors.every((c) => c.done)) {
        t.clock.advanceTo(next);
        check('t=${t.clock.nowMs} after [${sc.faults.join('; ')}]');
        next += 5000;
      }
      sc.quiet();
      t.run();
      check('at the end after [${sc.faults.join('; ')}]');

      final survivors = t.survivors.toList();
      expect(survivors, isNotEmpty);
      final finished = survivors.every((c) => c.done);
      if (finished) {
        final keysOf = [for (final c in survivors) c.record.map((d) => d.key).toList()];
        for (final r in keysOf) {
          expect(r, keysOf.first, reason: 'every survivor holds the same record');
        }
        final v = verifyRecord(t.spec, survivors.first.record);
        expect(v.ok && v.complete, isTrue, reason: v.reason);
      } else {
        for (final c in survivors) {
          expect(c.tableState, anyOf(TableState.pausedForJury, TableState.pausedForPeers),
              reason: 'not finished, so paused and saying why; faults were [${sc.faults.join('; ')}]\n${c.describe()}');
          final notAMajority = survivors.length < c.participants.length ~/ 2 + 1;
          expect(notAMajority || c.stuckSplit != null, isTrue,
              reason: 'paused only because the survivors are not a majority, or a turn split evenly; '
                  'faults were [${sc.faults.join('; ')}]\n${c.describe()}');
        }
      }
      t.stop();
    });
  }
}
