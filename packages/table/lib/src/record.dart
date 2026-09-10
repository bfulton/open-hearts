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
  const Verification({required this.ok, required this.reason, required this.winners, required this.ratings, required this.finalHolders});

  final bool ok;
  final String reason;

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
Verification verifyRecord(TableSpec spec, List<Decision> record) {
  final game = HeartsGame(seed: spec.seed);
  final holders = List.of(spec.seats);
  final humans = {for (final h in spec.seats) if (h is HumanSeat) h.key};
  final removedAt = <PublicKey, TurnId>{};
  final played = <Card>{};
  var index = 0;

  Verification fail(String why) =>
      Verification(ok: false, reason: why, winners: const [], ratings: const {}, finalHolders: holders);

  bool atOrBefore(TurnId a, TurnId b) {
    if (a.hand != b.hand) return a.hand < b.hand;
    final ai = a.isPass ? -1 : a.index;
    final bi = b.isPass ? -1 : b.index;
    return ai <= bi;
  }

  Set<PublicKey> participantsAt(TurnId turn) =>
      {for (final k in humans) if (!removedAt.containsKey(k) || !atOrBefore(removedAt[k]!, turn)) k};

  /// Whether [witnesses] carry a decision at [turn]. Removed members who
  /// witnessed count on both sides of the fraction. An action also
  /// carries when the whole table voted and split evenly ([opposed] is
  /// the other half).
  bool carried(Set<PublicKey> witnesses, TurnId turn, {Set<PublicKey> opposed = const {}}) {
    final of = participantsAt(turn).union(witnesses.intersection(removedAt.keys.toSet()));
    final needed = of.length ~/ 2 + 1;
    final backing = witnesses.intersection(of).length;
    if (backing >= needed) return true;
    final against = opposed.intersection(of).length;
    return against < needed && backing + against == of.length && witnesses.intersection(opposed).isEmpty;
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
        if (!carried(backers, d.turn)) return 'a ${e.kind.name} without a majority behind it';
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
      if (index >= record.length) return fail('the record ends mid-pass');
      final d = record[index++];
      final e = d.event;
      if (e.kind != EventKind.pass) return fail('expected a pass, saw ${e.kind.name}');
      final holder = holders[e.seat];
      if (holder is! HumanSeat || holder.key != e.author) return fail('a pass by a key that did not hold seat ${e.seat}');
      if (!carried(d.witnesses, d.turn, opposed: d.opposed)) {
        return fail('a pass at ${d.turn} by seat ${e.seat} without a majority behind it '
            '(${d.witnesses.length} of ${participantsAt(d.turn).length} seated)');
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
    if (index >= record.length) return fail('the record ends with seat $seat to play');
    final d = record[index++];
    final e = d.event;
    if (e.kind != EventKind.play) return fail('expected a play, saw ${e.kind.name}');
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != e.author || e.seat != seat) {
      return fail('a play by a key that did not hold seat $seat');
    }
    final turn = TurnId.play(game.handNumber, playIndex());
    if (d.turn != turn) return fail('a play recorded at $turn as ${d.turn}');
    if (!carried(d.witnesses, turn, opposed: d.opposed)) {
      return fail('a play at $turn by seat $seat without a majority behind it '
          '(${d.witnesses.length} of ${participantsAt(turn).length} seated)');
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
