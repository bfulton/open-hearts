/// Plays the bot against itself and reports how it does.
///
/// The suite proves the bot never breaks a rule. This says whether it
/// plays *well*, which no assertion can. Two numbers matter most:
///
///  - **wins by seat** should be flat. All four seats run the identical
///    bot, so a persistent skew is a positional bug, not strategy.
///  - **moons shot** is the defence gauge. Nobody here is trying to
///    shoot, so every moon is one the other three failed to break up.
///
/// Run it before and after touching bot.dart:
///
///     cd packages/engine && dart run --define=GAMES=2000 tool/bot_stats.dart
///
/// `PERSONA=<name>` seats four of one persona instead of four Westleys; the
/// tournament in test/persona_test.dart is where they meet each other.
library;

// A benchmark's entire output is its printing.
// ignore_for_file: avoid_print


import 'package:engine/engine.dart';

void main() {
  final games = int.parse(const String.fromEnvironment('OH_GAMES', defaultValue: '500'));
  const personaName = String.fromEnvironment('OH_PERSONA', defaultValue: 'Westley');
  final persona = Persona.named(personaName);
  final wins = List.filled(4, 0);
  final totalPts = List.filled(4, 0);
  var hands = 0, moons = 0, queenTaken = List.filled(4, 0);

  for (var seed = 0; seed < games; seed++) {
    final game = HeartsGame(seed: seed);
    final bot = Bot(persona: persona);
    final played = <Card>{};
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          for (var s = 0; s < seatCount; s++) {
            game.setPass(s, bot.choosePass(game.handOf(s)));
          }
          played.clear();
        case Phase.playing:
          if (game.pendingTrick != null) {
            final p = game.pendingTrick!;
            if (p.plays.any((x) => x.card == queenOfSpades)) {
              queenTaken[p.winner]++;
            }
            game.collectTrick();
            break;
          }
          final seat = game.currentSeat!;
          final view = BotView(
            seat: seat, hand: game.handOf(seat), trick: game.trick,
            played: played, heartsBroken: game.heartsBroken,
            isFirstTrick: game.isFirstTrick, taken: game.taken);
          final c = bot.chooseCard(view, game.legalPlaysFor(seat));
          game.play(seat, c);
          played.add(c);
        case Phase.handOver:
          hands++;
          if (game.moonShooter != null) moons++;
          game.nextHand();
          played.clear();
        case Phase.gameOver:
          break;
        case Phase.dealing:
          throw StateError('a seeded game deals itself');
      }
    }
    hands++;
    if (game.moonShooter != null) moons++;
    for (final w in game.winners) {
      wins[w]++;
    }
    for (var s = 0; s < 4; s++) {
      totalPts[s] += game.totals[s];
    }
  }

  print('$games games, $hands hands, four seats of ${persona.name}');
  print('wins by seat        : $wins   (fair share ${games ~/ 4})');
  print('mean final score    : ${totalPts.map((t) => (t / games).toStringAsFixed(1)).toList()}');
  print('queen taken by seat : $queenTaken');
  print('moons shot          : $moons  (${(100 * moons / hands).toStringAsFixed(1)}% of hands)');
  print('mean hands per game : ${(hands / games).toStringAsFixed(1)}');
}
