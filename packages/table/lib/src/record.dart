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
Verification verifyRecord(TableSpec spec, List<Decision> record) {
  final game = HeartsGame(seed: spec.seed);
  final holders = List.of(spec.seats);
  final participants = {for (final h in spec.seats) if (h is HumanSeat) h.key};
  final played = <Card>{};
  var index = 0;

  Verification fail(String why) =>
      Verification(ok: false, reason: why, winners: const [], ratings: const {}, finalHolders: holders);

  void botActs(int seat, {required bool passing}) {
    final persona = (holders[seat] as BotSeat).persona;
    final bot = Bot(persona: persona);
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

  /// Departures logged at this point in the record, before the next
  /// human action.
  bool takeRemovals() {
    while (index < record.length && record[index].removal) {
      final d = record[index++];
      final e = d.event;
      final seat = e.seat;
      final holder = holders[seat];
      if (holder is! HumanSeat) return true;
      if (e.kind == EventKind.leave) {
        if (e.author != holder.key) return false;
      } else {
        final needed = d.witnesses.length; // the snapshot is not in the record; require a majority of the participants then
        final majority = participants.length ~/ 2 + 1;
        if (needed < majority) return false;
        if (!d.witnesses.every(participants.contains) || d.witnesses.contains(holder.key)) return false;
      }
      participants.remove(holder.key);
      holders[seat] = BotSeat(spec.replacementFor(seat));
    }
    return true;
  }

  while (game.phase != Phase.gameOver) {
    if (!takeRemovals()) return fail('a removal without the standing to make it');
    if (game.phase == Phase.passing) {
      // Bots pass first, as every client does at the hand's start.
      for (var s = 0; s < seatCount; s++) {
        if (holders[s] is BotSeat && game.passOf(s) == null) botActs(s, passing: true);
      }
      if (game.phase == Phase.passing) {
        if (index >= record.length) return fail('the record ends mid-pass');
        final d = record[index++];
        final e = d.event;
        if (e.kind != EventKind.pass) return fail('expected a pass, saw ${e.kind.name}');
        final holder = holders[e.seat];
        if (holder is! HumanSeat || holder.key != e.author) return fail('a pass by a key that did not hold seat ${e.seat}');
        if (d.witnesses.length < participants.length ~/ 2 + 1) return fail('a pass without a majority behind it');
        final cards = [for (final c in e.body['cards'] as List) Card.parse(c as String)];
        try {
          game.setPass(e.seat, cards);
        } catch (_) {
          return fail('an illegal pass by seat ${e.seat}');
        }
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
    if (d.removal) {
      index--;
      if (!takeRemovals()) return fail('a removal without the standing to make it');
      continue;
    }
    if (e.kind != EventKind.play) return fail('expected a play, saw ${e.kind.name}');
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != e.author || e.seat != seat) {
      return fail('a play by a key that did not hold seat $seat');
    }
    if (d.witnesses.length < participants.length ~/ 2 + 1) return fail('a play without a majority behind it');
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
