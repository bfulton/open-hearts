/// One random walk through the simulator's faults, and the invariants
/// that must hold whatever happens: survivors never hold conflicting
/// decisions, every record verifies as far as it goes, every observed
/// state change is one the model in model.dart allows, and once the
/// faults stop and the network heals the table finishes — or is paused
/// for the one reason left, the jury gone and nobody online to draw
/// another. The test walks forty seeds on every commit; the tool walks
/// as many as asked, sealed too.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import '../client.dart';
import '../events.dart';
import '../model.dart';
import '../record.dart';
import '../signing.dart';
import 'scenarios.dart';
import 'sim_table.dart';

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
/// different actions, or an action by a seat that the other record
/// removed at that very turn instead. (A seat that passed and was then
/// claimed gone at its pass position holds both, in that order, and
/// that is one story, not two.)
String? conflict(List<Decision> a, List<Decision> b) {
  final actionsA = {for (final d in a) if (!d.removal) d.turn: d};
  final actionsB = {for (final d in b) if (!d.removal) d.turn: d};
  for (final t in actionsA.keys) {
    final x = actionsA[t]!;
    final y = actionsB[t];
    if (y != null && x.key != y.key) return 'two actions at $t: ${x.event} vs ${y.event}';
  }
  String? instead(List<Decision> r, Map<TurnId, Decision> actions, Decision d) {
    final removed = r.any((x) => x.removal && x.turn == d.turn && x.event.seat == d.event.seat);
    final held = actions[d.turn]?.key == d.key;
    if (removed && !held) return 'action by seat ${d.event.seat} at ${d.turn} vs its removal there';
    return null;
  }
  for (final d in a) {
    if (d.removal) continue;
    final why = instead(b, actionsB, d);
    if (why != null) return why;
  }
  for (final d in b) {
    if (d.removal) continue;
    final why = instead(a, actionsA, d);
    if (why != null) return why;
  }
  return null;
}

class _Observed {
  final Map<TurnId, TurnState> turns = {};
  final Map<int, SeatState> seats = {};
  TableState? table;
}

bool _sameList(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Walks [seed] to its end — sealed, with the verifiable deal run for
/// real, when [crypto] is given — and returns the first invariant it
/// broke, with the faults that led there, or null when every one held.
/// Whether any two sides still following the table read a different
/// juror for a bot seat, once everything has arrived.
///
/// The assignment is a function of the record — the hand's first jury
/// and the seats that were bots when the hand began — so two sides
/// that differ have read different records, and neither will take
/// what the other says for the seat: one waits for keys the other
/// juror is busy not making. It is legal for that to happen while a
/// draw or a departure is still in flight, which is what
/// `_refixHolders` repairs; what is never legal is for it to stand
/// after the faults have stopped and the network has healed.
///
/// A side that has heard no jury for the hand answers nothing, and
/// that is not a disagreement — it is a side that has not been told
/// yet.
///
/// The walk's other invariants are each about one side's own story:
/// the states it passes through, the record it holds, whether it
/// finishes. This is the one that asks two sides the same question.
String? disagreed(SimTable t) {
  final following = [
    ...t.survivors,
    for (final j in t.jurors)
      if (!j.gone && j.client != null) j.client!,
  ];
  var lastHand = 0;
  for (final c in following) {
    if (c.game.handNumber > lastHand) lastHand = c.game.handNumber;
  }
  String held(Map<int, PublicKey> m) =>
      (m.entries.map((e) => '${e.key}:${e.value.substring(0, 4)}').toList()..sort()).join(' ');
  for (var hand = 0; hand <= lastHand; hand++) {
    final answers = <String, List<String>>{};
    for (final c in following) {
      final h = c.botHolders(hand);
      if (h.isEmpty) continue;
      answers.putIfAbsent(held(h), () => []).add(c.signer.publicKey.substring(0, 4));
    }
    if (answers.length > 1) {
      return 'hand $hand: two sides read different jurors for its bot seats\n'
          '${answers.entries.map((e) => '  ${e.value.join(', ')}: ${e.key}').join('\n')}';
    }
  }
  return null;
}

String? walkChaos(int seed, {DealCrypto? crypto}) {
  final sc = ChaosScenario(seed, crypto: crypto);
  final t = sc.table;
  final observed = {for (final c in t.clients) c: _Observed()};
  String faults() => sc.faults.join('; ');

  String? check(String when) {
    final survivors = t.survivors.toList();
    for (var i = 0; i < survivors.length; i++) {
      for (var j = i + 1; j < survivors.length; j++) {
        final why = conflict(survivors[i].record, survivors[j].record);
        if (why != null) return '$when: a fork between two survivors: $why';
      }
    }
    for (final c in survivors) {
      final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries, crypto: t.crypto, releases: c.releases);
      if (!v.ok) return '$when: ${c.signer.publicKey.substring(0, 6)} record: ${v.reason}';
    }
    for (final c in t.clients) {
      final o = observed[c]!;
      for (final e in c.turnStates.entries) {
        final before = o.turns[e.key];
        if (before != null && before != e.value && !turnClosure[before]!.contains(e.value)) {
          return '$when: turn ${e.key} went $before → ${e.value}';
        }
        o.turns[e.key] = e.value;
      }
      for (var s = 0; s < seatCount; s++) {
        final now = c.seatStateOf(s);
        final before = o.seats[s];
        if (before != null && before != now && !seatClosure[before]!.contains(now)) {
          return '$when: seat $s went $before → $now';
        }
        o.seats[s] = now;
      }
      final now = c.tableState;
      final before = o.table;
      if (before != null && before != now && !tableClosure[before]!.contains(now)) {
        return '$when: table went $before → $now';
      }
      o.table = now;
    }
    return null;
  }

  try {
    t.start();
    sc.schedule();
    var next = 5000;
    while (t.clock.nowMs < sc.quietAt && !t.survivors.every((c) => c.done)) {
      t.clock.advanceTo(next);
      final why = check('t=${t.clock.nowMs} after [${faults()}]');
      if (why != null) return why;
      next += 5000;
    }
    sc.quiet();
    t.run();
    final why = check('at the end after [${faults()}]');
    if (why != null) return why;
    final apart = disagreed(t);
    if (apart != null) return '$apart; faults were [${faults()}]';

    final survivors = t.survivors.toList();
    final finished = survivors.every((c) => c.done);
    if (survivors.isEmpty) {
      // The last player still running was replaced while cut off, and
      // then everyone else went: a dead table. Every client still
      // running has to know it has no seat, and hold a sound record.
      for (final p in t.people.where((p) => !p.gone)) {
        if (p.client.amSeated) return 'a dead table, yet a client thinks it is seated; faults were [${faults()}]\n${p.client.describe()}';
        final v = verifyRecord(t.spec, p.client.record, allowPartial: true, juries: p.client.juries, crypto: t.crypto, releases: p.client.releases);
        if (!v.ok) return 'a dead table with an unsound record: ${v.reason}';
      }
    } else if (finished) {
      final keysOf = [for (final c in survivors) c.record.map((d) => d.key).toList()];
      for (final r in keysOf) {
        if (!_sameList(r, keysOf.first)) return 'survivors hold different records; faults were [${faults()}]';
      }
      final v = verifyRecord(t.spec, survivors.first.record, juries: survivors.first.juries, crypto: t.crypto, releases: survivors.first.releases);
      if (!(v.ok && v.complete)) return 'the finished record does not verify complete: ${v.reason}';
    } else {
      const paused = {TableState.pausedForJury, TableState.pausedForPeers, TableState.pausedForDeal};
      for (final c in survivors) {
        if (!paused.contains(c.tableState)) {
          return 'not finished, and not paused saying why; faults were [${faults()}]\n${c.describe()}';
        }
        if (c.tableState == TableState.pausedForDeal) {
          // A departed seat's hand that no juror is left to open: the
          // escrow's price, and only ever with the whole jury gone.
          if (c.pause != Pause.openingHand) {
            return 'paused for the deal for a reason other than an unopenable hand; faults were [${faults()}]\n${c.describe()}';
          }
          continue;
        }
        final notAMajority = survivors.length < c.participants.length ~/ 2 + 1;
        if (!(notAMajority || c.stuckSplit != null)) {
          return 'paused for a reason other than no majority or an even split; faults were [${faults()}]\n${c.describe()}';
        }
      }
      // With a jury there is no pause a live juror could not end.
      if (t.liveJurors.isNotEmpty) return 'paused with a juror still up; faults were [${faults()}]\n${survivors.first.describe()}';
    }
    return null;
  } finally {
    t.stop();
  }
}
