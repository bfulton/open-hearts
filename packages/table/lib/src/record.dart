/// A finished game, checked by anyone.
///
/// The record is the table spec and the decisions in order. Replaying
/// it rebuilds the game: every human action must be signed by the key
/// that held the seat and legal under the engine at that point, every
/// removal must carry the majority the participants of the moment
/// required, and every bot move is recomputed rather than read. The
/// ratings fall out of the replay by doc 04's two rules.
library;

import 'package:engine/engine.dart';

import 'client.dart';
import 'events.dart';
import 'signing.dart';
import 'spec.dart';

class Verification {
  const Verification({
    required this.ok,
    required this.reason,
    required this.winners,
    required this.ratings,
    required this.finalHolders,
    this.complete = true,
  });

  final bool ok;
  final String reason;

  /// Whether the record ran to the end of the game. A partial record can
  /// still be [ok]: everything in it checked.
  final bool complete;

  /// Winning seats, when the replay reached the end of the game.
  final List<int> winners;

  /// Rating change per human who ever held a seat: +1, −1, or 0.
  final Map<PublicKey, int> ratings;

  final List<SeatHolder> finalHolders;
}

/// Replays [record] against [spec].
///
/// The participants a majority is measured against at turn T are the
/// humans who sat down, less anyone removed by T — the client's rule.
/// One allowance: a peer settles the moment it holds a majority of the
/// set as it knows it, and a removal at the same position may not have
/// reached it yet, so a removed member who witnessed still counts, in
/// the denominator as well as the count. Nobody gains by that: it can
/// only raise the bar.
Verification verifyRecord(TableSpec spec, List<Decision> record, {bool allowPartial = false}) {
  final game = HeartsGame(seed: spec.seed);
  final holders = List.of(spec.seats);
  final humans = {for (final h in spec.seats) if (h is HumanSeat) h.key};
  final removedAt = <PublicKey, TurnId>{};
  final played = <Card>{};
  var index = 0;

  Verification fail(String why) =>
      Verification(ok: false, reason: why, winners: const [], ratings: const {}, finalHolders: holders);

  Verification partial() => Verification(
      ok: true, reason: 'verified so far', winners: const [], ratings: const {}, finalHolders: holders, complete: false);

  bool atOrBefore(TurnId a, TurnId b) {
    if (a.hand != b.hand) return a.hand < b.hand;
    final ai = a.isPass ? -1 : a.index;
    final bi = b.isPass ? -1 : b.index;
    return ai <= bi;
  }

  // Every change of a seat's holder in the record, wherever it sits —
  // removals, and seats taken back — in record order per person. The
  // smallest set a peer could legitimately have measured against at a
  // turn is everyone less those out by then, including ones recorded at
  // the same position but later in the record's order.
  final changes = <PublicKey, List<(TurnId, bool)>>{};
  for (final d in record) {
    if (!d.removal && !d.retake) continue;
    final h = spec.seats[d.event.seat];
    if (h is HumanSeat) changes.putIfAbsent(h.key, () => []).add((d.turn, d.removal));
  }
  bool presentAt(PublicKey k, TurnId turn, {TurnId? beforeRetakeAt}) {
    var present = true;
    for (final (at, removed) in changes[k] ?? const <(TurnId, bool)>[]) {
      if (!atOrBefore(at, turn)) break;
      if (!removed && beforeRetakeAt == at) break;
      present = !removed;
    }
    return present;
  }

  /// The floor at [turn]: everyone who sat down less those out by then.
  /// For the check of a retake itself, as of just before it.
  Set<PublicKey> floorAt(TurnId turn, {TurnId? beforeRetakeAt}) =>
      {for (final k in humans) if (presentAt(k, turn, beforeRetakeAt: beforeRetakeAt)) k};

  /// Whether a decision carries: a strict majority of [among], the set
  /// the peer measured against — which must be a legitimate one, every
  /// human who sat down less some of the removals made by [turn], never
  /// fewer than that.
  bool carried(Set<PublicKey> witnesses, TurnId turn, Set<PublicKey> among, {TurnId? beforeRetakeAt}) {
    if (among.isEmpty || !humans.containsAll(among)) return false;
    if (!among.containsAll(floorAt(turn, beforeRetakeAt: beforeRetakeAt))) return false;
    return witnesses.intersection(among).length >= among.length ~/ 2 + 1;
  }

  int playIndex() => game.tricksPlayed * seatCount + game.trick.length;

  /// No settled action next: the record's end, or a seat taken back at
  /// a hand the replay has not reached.
  bool endOfActions() => index >= record.length || record[index].retake;

  void botActs(int seat, {required bool passing}) {
    final bot = Bot(persona: (holders[seat] as BotSeat).persona);
    if (passing) {
      game.setPass(seat, bot.choosePass(game.handOf(seat)));
    } else {
      final view = BotView(
        seat: seat,
        hand: game.handOf(seat),
        trick: game.trick,
        played: played,
        heartsBroken: game.heartsBroken,
        isFirstTrick: game.isFirstTrick,
        taken: game.taken,
      );
      final card = bot.chooseCard(view, game.legalPlaysFor(seat));
      game.play(seat, card);
      played.add(card);
    }
  }

  void sweep() {
    if (game.pendingTrick != null) game.collectTrick();
    if (game.phase == Phase.handOver) {
      game.nextHand();
      played.clear();
    }
  }

  /// Applies the departures and the seats taken back recorded next,
  /// each checked against the participants at the turn it names.
  String? takeRemovals() {
    while (index < record.length && (record[index].removal || record[index].retake)) {
      // A seat taken back at a hand still to come stays where it is
      // until the replay opens that hand; the actions settled before
      // it are all in the record ahead of it.
      if (record[index].retake && record[index].turn.hand > game.handNumber) break;
      final d = record[index++];
      final e = d.event;
      final seat = e.seat;
      if (d.retake) {
        // A seat taken back: by its original person, from a bot, at
        // the pass turn of the hand the replay is opening, carried by a
        // majority of everyone present less themselves.
        final original = spec.seats[seat];
        if (e.kind != EventKind.retake || original is! HumanSeat || original.key != e.author) {
          return 'a retake of seat $seat by someone other than its person';
        }
        if (holders[seat] is! BotSeat || !removedAt.containsKey(e.author)) return 'a retake of a seat not given up';
        // At the start of the hand it names — before this seat's pass,
        // or before any card on a hand with no pass.
        final atStart = game.tricksPlayed == 0 &&
            game.trick.isEmpty &&
            (game.phase == Phase.passing ? game.passOf(seat) == null : game.phase == Phase.playing);
        if (!atStart || d.turn != TurnId.pass(game.handNumber, seat)) {
          return 'a retake of seat $seat at ${d.turn} out of place';
        }
        if (!carried(d.witnesses, d.turn, d.among, beforeRetakeAt: d.turn)) {
          return 'a retake of seat $seat at ${d.turn} without a majority behind it '
              '(${d.witnesses.intersection(d.among).length} of ${d.among.length})';
        }
        holders[seat] = HumanSeat(e.author);
        removedAt.remove(e.author);
        continue;
      }
      final holder = holders[seat];
      if (holder is! HumanSeat) continue;
      if (e.kind == EventKind.leave) {
        if (e.author != holder.key) return 'a leave signed by someone else';
      } else {
        final backers = Set.of(d.witnesses)..remove(holder.key);
        if (!carried(backers, d.turn, d.among)) {
          return 'a ${e.kind.name} of seat $seat at ${d.turn} without a majority behind it '
              '(${backers.length} of ${d.among.length})';
        }
      }
      removedAt[holder.key] = d.turn;
      holders[seat] = BotSeat(spec.replacementFor(seat));
    }
    return null;
  }

  while (game.phase != Phase.gameOver) {
    final why = takeRemovals();
    if (why != null) return fail(why);
    if (game.phase == Phase.passing) {
      for (var s = 0; s < seatCount; s++) {
        if (holders[s] is BotSeat && game.passOf(s) == null) botActs(s, passing: true);
      }
      if (game.phase != Phase.passing) continue;
      if (endOfActions()) return allowPartial ? partial() : fail('the record ends mid-pass');
      final d = record[index++];
      final e = d.event;
      if (e.kind != EventKind.pass) return fail('expected a pass, saw ${e.kind.name}');
      final holder = holders[e.seat];
      if (holder is! HumanSeat || holder.key != e.author) return fail('a pass by a key that did not hold seat ${e.seat}');
      if (!carried(d.witnesses, d.turn, d.among)) {
        return fail('a pass at ${d.turn} by seat ${e.seat} without a majority behind it '
            '(${d.witnesses.length} of ${d.among.length})');
      }
      try {
        game.setPass(e.seat, [for (final c in e.body['cards'] as List) Card.parse(c as String)]);
      } catch (_) {
        return fail('an illegal pass by seat ${e.seat}');
      }
      continue;
    }
    final seat = game.currentSeat!;
    if (holders[seat] is BotSeat) {
      botActs(seat, passing: false);
      sweep();
      continue;
    }
    if (endOfActions()) return allowPartial ? partial() : fail('the record ends with seat $seat to play');
    final d = record[index++];
    final e = d.event;
    if (e.kind != EventKind.play) return fail('expected a play, saw ${e.kind.name}');
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != e.author || e.seat != seat) {
      return fail('a play by a key that did not hold seat $seat');
    }
    final turn = TurnId.play(game.handNumber, playIndex());
    if (d.turn != turn) return fail('a play recorded at $turn as ${d.turn}');
    if (!carried(d.witnesses, turn, d.among)) {
      return fail('a play at $turn by seat $seat without a majority behind it '
          '(${d.witnesses.length} of ${d.among.length})');
    }
    final card = Card.parse(e.body['card'] as String);
    if (!game.legalPlaysFor(seat).contains(card)) return fail('an illegal play by seat $seat: $card');
    game.play(seat, card);
    played.add(card);
    sweep();
  }

  final winners = game.winners;
  final ratings = <PublicKey, int>{};
  final botWon = winners.any((s) => holders[s] is BotSeat);
  for (var s = 0; s < seatCount; s++) {
    final original = spec.seats[s];
    if (original is! HumanSeat) continue;
    ratings[original.key] = botWon ? 0 : (winners.contains(s) ? 1 : -1);
  }
  return Verification(ok: true, reason: 'verified', winners: winners, ratings: ratings, finalHolders: holders);
}
