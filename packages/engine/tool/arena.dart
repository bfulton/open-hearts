/// Prints the roster's standings against each other.
///
///     cd packages/engine && dart run --define=GAMES=3000 tool/arena.dart
///     dart run --define=ROSTER="Westley,Romeo,Don Juan,Roxane" tool/arena.dart
///
/// Fair share of wins is 25%. The test holds every persona to at least
/// 20% and within ten points of the best mean score; this is for seeing
/// where each actually lands when tuning one.
library;

// A benchmark's entire output is its printing.
// ignore_for_file: avoid_print

import 'package:engine/engine.dart';

void main() {
  final games = int.parse(const String.fromEnvironment('OH_GAMES', defaultValue: '1200'));
  // ROSTER=Westley,Don Juan,... seats a chosen field; default is the roster.
  const names = String.fromEnvironment('OH_ROSTER');
  final roster = names.isEmpty
      ? Persona.roster
      : [for (final n in names.split(',')) Persona.named(n.trim())];
  final standings = Arena.play(games, roster: roster)
    ..sort((a, b) => a.meanScore.compareTo(b.meanScore));
  print('$games tables, four from the roster at each\n');
  print('${'persona'.padRight(10)} ${'seats'.padLeft(6)} ${'wins'.padLeft(7)} ${'mean score'.padLeft(11)}');
  for (final s in standings) {
    print('${s.persona.name.padRight(10)} ${s.seats.toString().padLeft(6)} '
        '${(100 * s.winRate).toStringAsFixed(1).padLeft(6)}% '
        '${s.meanScore.toStringAsFixed(1).padLeft(11)}');
  }
}
