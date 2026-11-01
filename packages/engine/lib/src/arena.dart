/// Personas against each other.
///
/// The roster's one hard rule is that no character is bad, and the only
/// way to know is to play them. [Arena.play] seats a random four from
/// the roster at every table and reports how each persona did across
/// every seat it sat in. test/persona_test.dart asserts on the result;
/// tool/arena.dart prints it.
library;

import 'dart:math';

import 'bot.dart';
import 'game.dart';
import 'persona.dart';

/// How one persona fared over every table it sat at.
class Standing {
  Standing(this.persona, {required this.seats, required this.wins, required this.meanScore});

  final Persona persona;

  /// Tables sat at.
  final int seats;

  /// Tables won, a tie counting as a share of one.
  final double wins;

  /// Mean final score; lower is better.
  final double meanScore;

  double get winRate => wins / seats;
}

class Arena {
  /// Plays [games] seeded games with a random four from [roster] at each
  /// table. Deterministic in [games] and [roster].
  static List<Standing> play(int games, {List<Persona> roster = Persona.roster}) {
    final wins = {for (final p in roster) p: 0.0};
    final score = {for (final p in roster) p: 0};
    final seats = {for (final p in roster) p: 0};
    for (var seed = 0; seed < games; seed++) {
      // Drawn from a different stream than the deal, so the seating is
      // not a function of the cards and a character's luck does not
      // depend on its place in the roster.
      final draw = List.of(roster)..shuffle(Random(seed * 31 + 7));
      final table = draw.take(seatCount).toList();
      final result = playTable(seed, table);
      for (var s = 0; s < seatCount; s++) {
        wins[table[s]] = wins[table[s]]! + result.wins[s];
        score[table[s]] = score[table[s]]! + result.totals[s];
        seats[table[s]] = seats[table[s]]! + 1;
      }
    }
    return [
      for (final p in roster)
        Standing(p, seats: seats[p]!, wins: wins[p]!, meanScore: score[p]! / seats[p]!),
    ];
  }

  /// One seeded game with [table] in the seats. `wins` is 1 for the
  /// winner, a share for tied seats, 0 otherwise.
  static ({List<double> wins, List<int> totals}) playTable(int seed, List<Persona> table) {
    final bots = [for (final p in table) Bot(persona: p)];
    final game = HeartsGame(seed: seed);
    _playOut(game, bots);
    final won = game.winners;
    return (
      wins: [for (var s = 0; s < seatCount; s++) won.contains(s) ? 1 / won.length : 0.0],
      totals: game.totals,
    );
  }

  static void _playOut(HeartsGame game, List<Bot> bots) {
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          for (var s = 0; s < seatCount; s++) {
            game.setPass(s, bots[s].choosePass(game.handOf(s)));
          }
        case Phase.playing:
          if (game.pendingTrick != null) {
            game.collectTrick();
            break;
          }
          final seat = game.currentSeat!;
          final card = bots[seat].chooseCard(BotView.of(game, seat), game.legalPlaysFor(seat));
          game.play(seat, card);
        case Phase.handOver:
          game.nextHand();
        case Phase.gameOver:
          break;
        case Phase.dealing:
          throw StateError('a seeded game deals itself');
      }
    }
  }
}
