/// One random walk through the simulator's faults, and the invariants
/// that must hold whatever happens: survivors never hold conflicting
/// decisions, every record verifies as far as it goes, every observed
/// state change is one the model in model.dart allows, and once the
/// faults stop and the network heals no two sides still up hold a
/// held seat's escrow differently, and the table finishes — or is paused
/// for the one reason left, the jury gone and nobody online to draw
/// another, or has ended for it once that went on long enough. The
/// test walks forty seeds on every commit; the tool walks as many as
/// asked, sealed too.
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
import 'structure.dart';

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

/// [jurors] strangers to draw from, and with [sweep] each lets go of
/// the table once it has served, as the duty does ([SimTable]); its
/// clients' traces go to [jurorLog]. With [workers], every device
/// makes the deal's slow calls in a worker taking a browser's time.
String? walkChaos(int seed,
    {DealCrypto? crypto,
    StructureLog? structure,
    int jurors = 4,
    bool sweep = false,
    bool workers = false,
    void Function(String line)? jurorLog}) {
  final sc = ChaosScenario(seed, crypto: crypto, jurors: jurors, sweepJurors: sweep, workers: workers);
  final t = sc.table;
  for (final j in t.jurors) {
    j.log = jurorLog;
  }
  final observed = {for (final c in t.clients) c: _Observed()};
  String faults() => sc.faults.join('; ');

  // Up and following the table: a juror drawn whose summons never
  // reached it has no client, holds no piece it could release and
  // hears no appeal — and the table stops counting it thirty seconds
  // after the draw, having never heard from it.
  Set<PublicKey> upNow() => {for (final j in t.liveJurors) if (j.client != null) j.signer.publicKey};

  // And of those, the ones [c] can reach just now. A juror across a
  // partition is up and can do nothing for this side: nothing it says
  // arrives, and the side ends the game on exactly that silence, which
  // it cannot tell from a crash (doc 04, "When quorum is lost anyway").
  Set<PublicKey> reachableFrom(TableClient c) =>
      {for (final k in upNow()) if (t.net.canReach(c.signer.publicKey, k)) k};

  // Taken the instant each side ends the game, not at the next check:
  // a partition that heals in the five seconds between would make an
  // ending over a silence look like one with a juror in reach.
  final reachAtEnd = <TableClient, Set<PublicKey>>{};
  for (final c in t.clients) {
    c.changes.listen((_) {
      if (c.failure != null && !reachAtEnd.containsKey(c)) reachAtEnd[c] = reachableFrom(c);
    });
  }

  // A seat a side is stopped at, or ended the game at, that nobody
  // still up can open: a held seat with its own juror not among them
  // and fewer of the jurors holding a piece of it than it takes to
  // rebuild it; a departed person's with none of the jury the deal
  // was sealed to. The table stopped there says so (doc 03), no juror
  // up could end it, and after long enough the game ends (doc 04):
  // at a play, waiting for the jury; at the audit or a departed
  // seat's hand, stalled opening the hand. Judged here from who
  // really is up, not from what the table believes.
  bool unopenable(TableClient c, Set<PublicKey> up) {
    final w = c.waitingOnGoneJury;
    final f = c.failedAt;
    final waits = [
      if (w != null) (hand: w.turn.hand, seat: w.seat),
      if (f != null) (hand: f.turn.hand, seat: f.seat),
      for (final e in c.stalled.entries) (hand: e.key.hand, seat: e.value),
    ];
    if (waits.isEmpty) return false;
    return waits.every((x) => !c.openableBy(x.hand, x.seat, up.contains));
  }

  // Stopped where nobody really up could move the table: a seat nobody
  // up could open, or a turn put to the jury — split, or open while
  // the table waits for want of a majority — with none of the hand's
  // jurors up to rule on it. The game ends there (doc 04), and only
  // there.
  bool immovable(TableClient c, Set<PublicKey> up) {
    if (unopenable(c, up)) return true;
    final f = c.failedAt;
    final hand = f?.turn.hand ?? c.game.handNumber;
    final putToJury = f != null || c.tableState == TableState.pausedForJury || c.tableState == TableState.pausedForPeers;
    return putToJury && !c.jurorsOf(hand).any(up.contains);
  }

  // A game ended for a lost quorum is judged the moment it is seen,
  // against who is up then: a juror blipped away and back later would
  // make it look premature at the end of the walk when it was not.
  final judged = <TableClient>{};

  String? check(String when) {
    // Read only: what each side waits for, for docs/07-states.md.
    structure?.take(t);
    final survivors = t.survivors.toList();
    for (final c in survivors) {
      if (c.failure == null || !judged.add(c)) continue;
      if (!immovable(c, reachAtEnd[c] ?? reachableFrom(c))) {
        return '$when: ${c.signer.publicKey.substring(0, 6)} ended the game, ${c.failure!.label}, '
            'with a juror it could reach that could move the table\n${c.describe()}';
      }
    }
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
    // A juror has no part in a hand that was over before its summons,
    // and every way of taking one is closed where it starts: the
    // client's last refusal ([TableClient.saidBeforeSummons]) is never
    // what stops it.
    for (final j in t.jurors) {
      if (j.saidBeforeSummons > 0) {
        return '$when: juror ${j.signer.publicKey.substring(0, 4)} went to say something about a hand before its summons';
      }
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
    // A held seat given to the escrow is on the record, so once the
    // faults have stopped and the network has healed, two sides still
    // playing at the same hand hold the seat alike: anything else is
    // two records, not a message in flight (docs/07-states.md). Not a
    // side whose game has ended for a lost quorum: it says nothing new,
    // and a claim it carried just before is one the others may never
    // hear — over a game that is over, and unscored (sealed seed 2).
    final playing = [
      for (final p in t.people)
        if (!p.gone && p.client.failure == null) p.client,
      for (final j in t.jurors)
        if (!j.gone && j.client != null && j.client!.serving && j.client!.failure == null) j.client!,
    ];
    final byHand = <int, List<TableClient>>{};
    for (final c in playing) {
      byHand.putIfAbsent(c.game.handNumber, () => []).add(c);
    }
    for (final MapEntry(key: hand, value: at) in byHand.entries) {
      for (var seat = 0; seat < seatCount; seat++) {
        final states = {for (final c in at) c.heldSeatState(seat)}..remove(null);
        if (states.length > 1) return 'apart on the escrow at the end: hand $hand seat $seat; faults were [${faults()}]';
      }
    }
    // And the way each person went, on every record that has it — the
    // jurors' beside the people's, those that have stopped serving and
    // those whose game ended for a lost quorum among them, since a
    // record holds only what carried. A leave is carried as a boot is
    // now, so a seat left on one record and booted on another is two
    // majorities. The record's key for a removal names its turn and
    // seat and not the door, and records compared alike with a leave on
    // one and a boot on the other; the jurors kept theirs for as long as
    // they served (chaos seed 43).
    final records = [
      for (final p in t.people) p.client,
      for (final j in t.jurors)
        if (j.client != null) j.client!,
    ];
    for (var seat = 0; seat < seatCount; seat++) {
      final exits = <String, List<String>>{};
      for (final c in records) {
        for (final d in c.record) {
          final kind = d.event.kind;
          if (!d.removal || d.event.seat != seat || !(kind == EventKind.leave || kind == EventKind.boot || kind == EventKind.absent)) continue;
          exits.putIfAbsent('${kind.name} at ${d.turn}', () => []).add(c.signer.publicKey.substring(0, 4));
        }
      }
      if (exits.length > 1) {
        return 'apart on a seat at the end: seat $seat ${exits.entries.map((e) => '${e.key} at ${e.value.join(', ')}').join('; ')}; '
            'faults were [${faults()}]';
      }
    }

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
      final up = upNow();
      const paused = {TableState.pausedForJury, TableState.pausedForPeers, TableState.pausedForDeal};
      for (final c in survivors) {
        // Ended for a lost quorum, and judged fair when it was seen.
        if (c.tableState == TableState.failed) continue;
        // Stopped for good where nobody up could move it: the game
        // ends rather than wait on a jury that is gone.
        if (immovable(c, up)) {
          return 'stopped for good where nobody up could move the table, and the game did not end; '
              'faults were [${faults()}]\n${c.describe()}';
        }
        if (!paused.contains(c.tableState)) {
          return 'not finished, and not paused saying why; faults were [${faults()}]\n${c.describe()}';
        }
        if (c.tableState == TableState.pausedForDeal) {
          // A departed seat's hand that no juror is left to open: the
          // escrow's price, and only ever with the whole jury gone —
          // which, left long enough, ends the game.
          if (c.pause != Pause.openingHand) {
            return 'paused for the deal for a reason other than an unopenable hand; faults were [${faults()}]\n${c.describe()}';
          }
          continue;
        }
        final notAMajority = survivors.length < c.participants.length ~/ 2 + 1;
        if (!(notAMajority || c.stuckSplit != null || unopenable(c, up))) {
          return 'paused for a reason other than no majority or an even split; faults were [${faults()}]\n${c.describe()}';
        }
      }
      // With a jury there is no pause a live juror could not end — save
      // the one above, which none could.
      if (up.isNotEmpty && !survivors.where((c) => c.failure == null).every((c) => unopenable(c, up))) {
        return 'paused with a juror still up; faults were [${faults()}]\n${survivors.first.describe()}';
      }
    }
    return null;
  } finally {
    t.stop();
  }
}
