/// Every side's state read at one moment, and the ways a table can be
/// stuck that are facts about those states rather than about how long
/// anything has taken (docs/07-states.md, "Stuck").
///
/// Each side says what it waits for and who can end each wait
/// ([TableClient.waits]). A wait is covered when one of those who can
/// end it is up and holds the thing to end it with, or is on its way
/// to it: the action said or owed, a backing given, the turn decided on
/// the record for a side behind to be carried to, a piece of a seat it
/// has given up. It is stuck when nobody up can end it, or when
/// everybody who could has already left it behind in a way no rule
/// brings back — moved past its hand without deciding it, closed it
/// with nothing said, or never given up the seat whose pieces are
/// wanted — or when the sides able to end it wait on each other at it.
///
/// Beside those, the things each side decides for itself
/// ([Decided.here]) are compared across sides. Two sides apart on them
/// is not stuck in itself; it is what the stuck readings above have
/// been made of.
///
/// Up means not gone for good. A side cut off for a while is coming
/// back, and a wait on it is a wait. A side offline when a reading is
/// taken is still read, and what it reads is marked cut off: a device
/// on its own deciding differently from the table, as against the
/// table deciding differently from itself.
///
/// For measuring, in the simulator, where every side can be read at
/// once. It decides nothing, and reading it changes nothing. Most of
/// what it reads mid-run passes: a disagreement while an event is in
/// flight, a wait on someone gone before anyone has noticed. What is
/// still read when a run ends is what nothing was going to end.
library;

import '../client.dart';
import '../events.dart';
import '../model.dart';
import '../signing.dart';
import 'sim_table.dart';

/// How a wait can be stuck.
enum Stuck {
  /// Nobody who could end it is up. A side can say why it waits — a
  /// pause — and still wait for good.
  onNobody,

  /// Everybody up who could end it has left it behind: moved past its
  /// hand without deciding it, closed it with nothing said, never given
  /// up the seat whose pieces it wants, or ended the game without it.
  leftBehind,

  /// The sides able to end it wait on each other at it, and none of
  /// them has a way out.
  cycle,
}

/// What sides can be apart on because each decides it for itself.
enum Apart {
  /// A held bot seat given to the escrow at one side and not another.
  escrow,

  /// A hand abandoned at one side and dealt or played on at another.
  handOutcome,

  /// A hand's deal sealed to different jury draws.
  sealedTo,

  /// The game ended for a lost quorum at one side and not another.
  failure,

  /// A turn closed with nothing said at one side and settled by an
  /// action on the record at another: the two records differ at it.
  turnOutcome,

  /// A person removed at different turns at two sides — a leave at one,
  /// a boot at the other — or removed at one side and still seated at
  /// another that has moved past the hand the removal was made in.
  seat,
}

class Finding {
  const Finding(this.what, this.side, this.detail, {this.cutOff = false});

  /// A [Stuck] or an [Apart].
  final Enum what;
  final PublicKey side;
  final String detail;

  /// A side it is about is offline at the reading: a device cut off
  /// from the table, rather than the table disagreeing with itself.
  final bool cutOff;

  @override
  String toString() => '${what.name} at ${side.substring(0, 4)}: $detail${cutOff ? ' (cut off)' : ''}';
}

/// Every stuck wait and every disagreement at this moment.
List<Finding> readStructure(SimTable t) {
  // A juror no longer serving is one its host closes (JurorDuty), and
  // the simulator's never does.
  final sides = <PublicKey, TableClient>{
    for (final p in t.people)
      if (!p.gone) p.client.signer.publicKey: p.client,
    for (final j in t.jurors)
      if (!j.gone && j.client != null && j.client!.serving) j.signer.publicKey: j.client!,
  };
  // Up is not gone for good. A side cut off for a while — a blip, a
  // partition, a relay down — is coming back, and a wait on it is a
  // wait, not a stall.
  bool up(PublicKey k) => sides.containsKey(k);
  // Offline at this moment, for marking what a cut-off side reads.
  bool off(PublicKey k) => !t.net.isUp(k);
  final out = <Finding>[];

  // Per turn, the sides waiting at it with nothing but each other to
  // wait on, and whom they wait on.
  final open = <TurnId, Map<PublicKey, Set<PublicKey>>>{};
  final holding = <TurnId, Map<PublicKey, String>>{};

  for (final MapEntry(key: me, value: c) in sides.entries) {
    if (!up(me) || c.done || c.failure != null) continue;
    for (final w in c.waits) {
      if (w.outside) continue;
      final t0 = w.turn;
      final movers = w.movers.where(up).toSet();
      // Paused or not: a pause says why a side waits, and a wait nobody
      // up can end is waited on for good all the same.
      final paused = c.tableState == TableState.playing ? '' : ' (${c.tableState.name})';
      if (movers.isEmpty) {
        out.add(Finding(Stuck.onNobody, me, '$w$paused', cutOff: off(me)));
        continue;
      }
      // A seat's secret takes enough of its pieces, not one: a held
      // seat's own juror or a quorum of those holding a piece of it; a
      // departed person's, one of the jury it was sealed to.
      final seat0 = w.seat;
      if (w.kind == WaitKind.secret && t0 != null && seat0 != null && !c.openableBy(t0.hand, seat0, up)) {
        out.add(Finding(Stuck.onNobody, me, '$w$paused: too few of its pieces held by anyone up', cutOff: off(me)));
        continue;
      }
      if (t0 == null) continue;
      var covered = false;
      final behind = <String>[];
      final onEach = <PublicKey>{};
      for (final m in movers) {
        if (m == me) {
          covered = true;
          break;
        }
        final r = _relation(w, t0, c, sides[m]!);
        switch (r) {
          case _Rel.covered:
            covered = true;
          case _Rel.waiting:
            onEach.add(m);
          case _Rel.past:
            behind.add('${m.substring(0, 4)} moved past hand ${t0.hand} without deciding it');
          case _Rel.silent:
            behind.add('${m.substring(0, 4)} closed it with nothing said');
          case _Rel.notGivenUp:
            behind.add('${m.substring(0, 4)} never gave seat ${w.seat} up');
          case _Rel.finished:
            behind.add('${m.substring(0, 4)} finished the game without it');
          case _Rel.ended:
            behind.add('${m.substring(0, 4)} ended the game');
        }
        if (covered) break;
      }
      if (covered) continue;
      if (onEach.isEmpty) {
        out.add(Finding(Stuck.leftBehind, me, '$w: ${behind.join('; ')}', cutOff: off(me)));
      } else {
        open.putIfAbsent(t0, () => {})[me] = onEach;
        final a = c.actionAt(t0);
        holding.putIfAbsent(t0, () => {})[me] = a == null ? 'nothing' : '${a.kind.name} ${a.id.substring(0, 6)} by ${a.author.substring(0, 4)}';
      }
    }
  }

  // Waiting on each other: a side whose movers all wait at the turn
  // too is out only if one of them is out. Whatever is left after
  // letting everyone out that can be is a cycle.
  for (final MapEntry(key: turn, value: waiting) in open.entries) {
    final out0 = <PublicKey>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final MapEntry(key: side, value: on) in waiting.entries) {
        if (out0.contains(side)) continue;
        if (on.any((m) => !waiting.containsKey(m) || out0.contains(m))) {
          out0.add(side);
          changed = true;
        }
      }
    }
    for (final side in waiting.keys) {
      if (!out0.contains(side)) {
        out.add(Finding(Stuck.cycle, side,
            'at $turn, holding ${holding[turn]![side]}, on ${waiting[side]!.map((k) => k.substring(0, 4)).toList()}',
            cutOff: off(side)));
      }
    }
  }

  out.addAll(_apart(sides, up, off));
  return out;
}

enum _Rel { covered, waiting, past, silent, notGivenUp, finished, ended }

/// Where mover [m] stands on the turn [c] waits at.
_Rel _relation(Wait w, TurnId turn, TableClient c, TableClient m) {
  // A game ended for a lost quorum says nothing more, and hears nothing.
  if (m.failure != null) return _Rel.ended;
  final st = m.turnStateOf(turn);
  switch (st) {
    case TurnState.settledByAction:
    case TurnState.settledByRemoval:
    case TurnState.ended:
      // On the record, at whatever hand, and carried to whoever is
      // behind — by a side whose game is over, too.
      return _Rel.covered;
    case TurnState.settledSilently:
      // Closed with nothing said. For a bot seat nobody holds, its move
      // worked out from the record, which a side not there yet reaches
      // by the removal that made the seat one; for a held seat, its
      // audit closed from the escrow's pieces once the record gave it
      // to the escrow, which a side behind is carried to. Anything else
      // closed silently at a held seat is this mover's own judgement.
      final seat = w.seat;
      if (seat == null || m.botHolders(turn.hand)[seat] == null) return _Rel.covered;
      return m.escrowedAt(turn.hand).containsKey(seat) ? _Rel.covered : _Rel.silent;
    case TurnState.open:
    case TurnState.acting:
    case TurnState.contested:
    case TurnState.split:
    case null:
      break;
  }
  // Anything else a finished side will never get to.
  if (m.done) return _Rel.finished;
  final mh = m.game.handNumber;
  if (mh < turn.hand) return _Rel.covered; // it has yet to get there
  if (mh > turn.hand) return _Rel.past;
  if (st == null) return _Rel.covered; // not opened there yet
  switch (w.kind) {
    case WaitKind.action:
      // The seat's actor, at the turn: it owes the move, or has made
      // it and says it again until it settles.
      return _Rel.covered;
    case WaitKind.witnesses:
      // A juror gives no backing; it rules once the voters can carry
      // neither side — a silent voter's, or two voices for a bot seat —
      // and not before.
      if (m.mySeat == null) return _Rel.covered;
      // Backing it has given for the same action is said again until
      // the turn settles; an action it has not got is carried to it.
      final mine = c.actionAt(turn);
      final theirs = m.actionAt(turn);
      if (theirs == null) return _Rel.covered;
      if (mine != null && theirs.id == mine.id && m.backs(turn)) return _Rel.covered;
      return _Rel.waiting;
    case WaitKind.secret:
      // Pieces are said by a side for a seat it has given up itself.
      return m.goneSeats.contains(w.seat) ? _Rel.covered : _Rel.notGivenUp;
    case WaitKind.verdict:
    case WaitKind.jury:
      return _Rel.covered;
  }
}

/// Where sides stand apart on what each decides for itself.
List<Finding> _apart(Map<PublicKey, TableClient> sides, bool Function(PublicKey) up, bool Function(PublicKey) off) {
  final out = <Finding>[];
  final live = {for (final e in sides.entries) if (up(e.key)) e.key: e.value};
  String k(PublicKey p) => p.substring(0, 4);
  // A held seat, as the sides at the same hand have it.
  final byHand = <int, Map<PublicKey, TableClient>>{};
  for (final e in live.entries) {
    byHand.putIfAbsent(e.value.game.handNumber, () => {})[e.key] = e.value;
  }
  for (final MapEntry(key: hand, value: at) in byHand.entries) {
    for (var seat = 0; seat < 4; seat++) {
      final escrowed = <PublicKey>{};
      final held = <PublicKey>{};
      for (final e in at.entries) {
        switch (e.value.heldSeatState(seat)) {
          case HeldSeatState.escrowed:
            escrowed.add(e.key);
          case HeldSeatState.held:
            held.add(e.key);
          case null:
            break;
        }
      }
      if (escrowed.isNotEmpty && held.isNotEmpty) {
        // Cut off unless the sides still online disagree among themselves.
        final cut = escrowed.every(off) || held.every(off);
        out.add(Finding(Apart.escrow, escrowed.first,
            'hand $hand seat $seat: escrowed at ${escrowed.map(k).toList()}, held at ${held.map(k).toList()}',
            cutOff: cut));
      }
    }
  }
  // A hand abandoned at one side and not at another.
  for (final MapEntry(key: a, value: ca) in live.entries) {
    for (final MapEntry(key: b, value: cb) in live.entries) {
      if (a.compareTo(b) >= 0) continue;
      final cut = off(a) || off(b);
      final hands = {...Iterable<int>.generate(ca.game.handNumber), ...Iterable<int>.generate(cb.game.handNumber)};
      for (final h in hands) {
        final oa = ca.handOutcome(h);
        final ob = cb.handOutcome(h);
        final abandonedA = oa == HandState.abandoned;
        final abandonedB = ob == HandState.abandoned;
        // Only where both have left the hand behind, or one is still in
        // it: a side yet to reach it has decided nothing.
        final aIn = ca.game.handNumber == h, bIn = cb.game.handNumber == h;
        if (abandonedA != abandonedB && (oa != null || aIn) && (ob != null || bIn) && (oa != null || ob != null)) {
          out.add(Finding(Apart.handOutcome, a, 'hand $h: ${k(a)} ${oa?.name ?? 'still in it'}, ${k(b)} ${ob?.name ?? 'still in it'}', cutOff: cut));
        }
      }
      final sa0 = ca.turnStates, sb0 = cb.turnStates;
      for (final MapEntry(key: turn, value: x) in sa0.entries) {
        final y = sb0[turn];
        final silentA = x == TurnState.settledSilently, silentB = y == TurnState.settledSilently;
        final actionA = x == TurnState.settledByAction, actionB = y == TurnState.settledByAction;
        if ((silentA && actionB) || (actionA && silentB)) {
          out.add(Finding(Apart.turnOutcome, a, '$turn: ${k(a)} ${x.name}, ${k(b)} ${y!.name}', cutOff: cut));
        }
      }
      final shared = ca.game.handNumber < cb.game.handNumber ? ca.game.handNumber : cb.game.handNumber;
      for (var h = 0; h <= shared; h++) {
        final sa = ca.sealedTo(h), sb = cb.sealedTo(h);
        if (sa != null && sb != null && sa != sb) {
          out.add(Finding(Apart.sealedTo, a, 'hand $h: ${k(a)} sealed to ${sa.substring(0, 6)}, ${k(b)} to ${sb.substring(0, 6)}', cutOff: cut));
        }
      }
      // A person removed at one side, still seated at another that is
      // past the hand of the removal.
      for (var seat = 0; seat < 4; seat++) {
        final ra = ca.removedAt(seat), rb = cb.removedAt(seat);
        if (ra == rb) continue;
        String at(TurnId? r) => r == null ? 'still seated' : 'removed at $r';
        final laterHand = (ra ?? rb)!.hand;
        final other = ra == null ? ca : cb;
        if ((ra != null && rb != null) || other.game.handNumber > laterHand || other.done) {
          out.add(Finding(Apart.seat, a, 'seat $seat: ${k(a)} ${at(ra)}, ${k(b)} ${at(rb)}', cutOff: cut));
        }
      }
      if ((ca.failure == null) != (cb.failure == null) && ca.mySeat != null && cb.mySeat != null) {
        out.add(Finding(Apart.failure, a, '${k(a)} ${ca.failure?.label ?? 'playing'}, ${k(b)} ${cb.failure?.label ?? 'playing'}', cutOff: cut));
      }
    }
  }
  return out;
}

/// Readings gathered over a run: each distinct finding once, with when
/// it was first and last seen, so a disagreement that lasted a moment
/// and one that never ended read differently.
class StructureLog {
  final Map<String, ({Finding finding, int first, int last})> seen = {};

  /// When the last reading was taken.
  int? lastTaken;

  void take(SimTable t) {
    final now = lastTaken = t.clock.nowMs;
    for (final f in readStructure(t)) {
      final key = '${f.what.name}|${f.side}|${f.detail}|${f.cutOff}';
      final was = seen[key];
      seen[key] = (finding: f, first: was?.first ?? now, last: now);
    }
  }

  /// Distinct findings of each kind, at any reading.
  Map<Enum, int> get counts => _count(seen.values);

  /// Those still read at the last reading: a run that ended with them.
  Map<Enum, int> get standing => _count(seen.values.where((e) => e.last == lastTaken));

  /// Of those, the ones among sides still online: the table at odds
  /// with itself, not with a device cut off from it.
  Map<Enum, int> get standingOnline => _count(seen.values.where((e) => e.last == lastTaken && !e.finding.cutOff));

  static Map<Enum, int> _count(Iterable<({Finding finding, int first, int last})> of) {
    final out = <Enum, int>{};
    for (final e in of) {
      out[e.finding.what] = (out[e.finding.what] ?? 0) + 1;
    }
    return out;
  }
}
