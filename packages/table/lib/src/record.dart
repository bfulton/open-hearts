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
import 'jury.dart';
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
///
/// A decision the players could not carry may be carried by a juror's
/// verdict instead ([juries]: the jury proposals that carried at this
/// peer). Each jury must itself be carried by a majority of the
/// participants of its moment and be the draw its snapshot gives; a
/// verdict must be by a juror of the hand, about this turn and this
/// seat, ruling for the very event recorded.
Verification verifyRecord(TableSpec spec, List<Decision> record, {bool allowPartial = false, List<Decision> juries = const []}) {
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

  // Every removal in the record, wherever it sits: the smallest set a
  // peer could legitimately have measured against at a turn is everyone
  // less all of these made by then — including ones recorded at the
  // same position but later in the record's order.
  final allRemovals = <PublicKey, TurnId>{};
  for (final d in record) {
    if (!d.removal) continue;
    final h = spec.seats[d.event.seat];
    if (h is HumanSeat && !allRemovals.containsKey(h.key)) allRemovals[h.key] = d.turn;
  }
  Set<PublicKey> floorAt(TurnId turn) =>
      {for (final k in humans) if (!allRemovals.containsKey(k) || !atOrBefore(allRemovals[k]!, turn)) k};

  /// Whether a decision carries: a strict majority of [among], the set
  /// the peer measured against — which must be a legitimate one, every
  /// human who sat down less some of the removals made by [turn], never
  /// fewer than that.
  bool carried(Set<PublicKey> witnesses, TurnId turn, Set<PublicKey> among) {
    if (among.isEmpty || !humans.containsAll(among)) return false;
    if (!among.containsAll(floorAt(turn))) return false;
    return witnesses.intersection(among).length >= among.length ~/ 2 + 1;
  }

  final jurors = <int, Set<PublicKey>>{};
  for (final d in juries) {
    final e = d.event;
    if (!d.jury || e.kind != EventKind.jury) return fail('a jury that is not a jury proposal');
    if (!humans.contains(e.author)) return fail('a jury proposed by someone not at the table');
    List<PublicKey> snapshot;
    List<PublicKey> drawn;
    try {
      snapshot = e.snapshot;
      drawn = e.jurors;
    } catch (_) {
      return fail('a malformed jury proposal');
    }
    if (snapshot.any(humans.contains)) return fail('a jury drawn from the table itself');
    final expected = drawJury(spec.seed, e.hand, snapshot);
    if (expected.length != drawn.length || Iterable.generate(drawn.length).any((i) => expected[i] != drawn[i])) {
      return fail('a jury for hand ${e.hand} that is not the draw its snapshot gives');
    }
    if (!carried(d.witnesses, d.turn, d.among)) {
      return fail('a jury for hand ${e.hand} without a majority behind it (${d.witnesses.length} of ${d.among.length})');
    }
    jurors.putIfAbsent(e.hand, () => {}).addAll(drawn);
  }

  /// The jurors in force at [hand]: its own, or until it has any, the
  /// latest earlier hand's — the client's rule, a juror serves until
  /// relieved.
  Set<PublicKey> jurorsAt(int hand) {
    var latest = -1;
    for (final h in jurors.keys) {
      if (h <= hand && h > latest) latest = h;
    }
    return latest < 0 ? const {} : jurors[latest]!;
  }

  /// Whether [d] is carried by a verdict: a juror of the hand ruled
  /// for exactly this event at exactly this turn.
  bool byVerdict(Decision d) {
    final v = d.verdict;
    if (v == null || v.kind != EventKind.verdict) return false;
    if (!jurorsAt(d.turn.hand).contains(v.author)) return false;
    try {
      if (v.turn != d.turn || v.seat != d.event.seat) return false;
      if ((v.side == 'removal') != d.removal) return false;
      final ruled = v.ruled;
      return ruled != null && ruled.id == d.event.id;
    } catch (_) {
      return false;
    }
  }

  int playIndex() => game.tricksPlayed * seatCount + game.trick.length;

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

  /// Applies the departures recorded next, each checked against the
  /// participants at the turn it names.
  String? takeRemovals() {
    while (index < record.length && record[index].removal) {
      final d = record[index++];
      final e = d.event;
      final seat = e.seat;
      final holder = holders[seat];
      if (holder is! HumanSeat) continue;
      if (e.kind == EventKind.leave) {
        if (e.author != holder.key) return 'a leave signed by someone else';
      } else {
        final backers = Set.of(d.witnesses)..remove(holder.key);
        if (!carried(backers, d.turn, d.among) && !byVerdict(d)) {
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
      if (index >= record.length) return allowPartial ? partial() : fail('the record ends mid-pass');
      final d = record[index++];
      final e = d.event;
      if (e.kind != EventKind.pass) return fail('expected a pass, saw ${e.kind.name}');
      final holder = holders[e.seat];
      if (holder is! HumanSeat || holder.key != e.author) return fail('a pass by a key that did not hold seat ${e.seat}');
      if (!carried(d.witnesses, d.turn, d.among) && !byVerdict(d)) {
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
    if (index >= record.length) return allowPartial ? partial() : fail('the record ends with seat $seat to play');
    final d = record[index++];
    final e = d.event;
    if (e.kind != EventKind.play) return fail('expected a play, saw ${e.kind.name}');
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != e.author || e.seat != seat) {
      return fail('a play by a key that did not hold seat $seat');
    }
    final turn = TurnId.play(game.handNumber, playIndex());
    if (d.turn != turn) return fail('a play recorded at $turn as ${d.turn}');
    if (!carried(d.witnesses, turn, d.among) && !byVerdict(d)) {
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
