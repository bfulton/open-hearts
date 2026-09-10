/// What each persona setting is worth on its own.
///
///     cd packages/engine && dart run --define=GAMES=2000 tool/knobs.dart
///
/// Seats one bot that differs from Westley by a single setting against
/// three Westleys, rotating the seat, and reports its win rate and mean
/// score against the 25% and the score a fourth Westley would get. This
/// is how a persona gets tuned: a setting that costs several points on
/// its own has no business in a character, however apt.
library;

// A benchmark's entire output is its printing.
// ignore_for_file: avoid_print

import 'package:engine/engine.dart';

void main() {
  final games = int.parse(const String.fromEnvironment('GAMES', defaultValue: '1000'));
  const base = Persona.westley;
  final variants = <Persona>[
    base,
    const Persona(name: 'no shot', epithet: '', shootLoserShare: 0),
    const Persona(name: 'shot 3', epithet: '', shootLoserShare: 3),
    const Persona(name: 'shot 3 pass 7', epithet: '', shootLoserShare: 3, shootPassMaxLosers: 7),
    const Persona(name: 'shot 5', epithet: '', shootLoserShare: 5),
    const Persona(name: 'pass 4', epithet: '', shootPassMaxLosers: 4),
    const Persona(name: 'pass 7', epithet: '', shootPassMaxLosers: 7),
    const Persona(name: 'no stopper', epithet: '', keepsStopper: false),
    const Persona(name: 'flush 2', epithet: '', flushMinSmallSpades: 2),
    const Persona(name: 'flush 3', epithet: '', flushMinSmallSpades: 3),
    const Persona(name: 'defend 3', epithet: '', moonDefenseTrigger: 3),
    const Persona(name: 'defend 6', epithet: '', moonDefenseTrigger: 6),
    const Persona(name: 'defend 8', epithet: '', moonDefenseTrigger: 8),
    const Persona(name: 'pass keepQ', epithet: '', passStyle: PassStyle.keepQueen),
    const Persona(name: 'pass dumpQ', epithet: '', passStyle: PassStyle.dumpQueen),
    const Persona(name: 'lead long/low', epithet: '', leadFrom: LeadFrom.longestWhileLow),
    const Persona(name: 'long/low ≤5', epithet: '', leadFrom: LeadFrom.longestWhileLow, longLeadMaxRank: 5),
    const Persona(name: 'long/low ≤4', epithet: '', leadFrom: LeadFrom.longestWhileLow, longLeadMaxRank: 4),
    const Persona(name: 'long/low ≤3', epithet: '', leadFrom: LeadFrom.longestWhileLow, longLeadMaxRank: 3),
  ];
  print('$games games each, one variant against three Westleys\n');
  print('${'variant'.padRight(14)} ${'wins'.padLeft(7)} ${'mean score'.padLeft(11)}');
  for (final v in variants) {
    var wins = 0.0;
    var score = 0;
    for (var seed = 0; seed < games; seed++) {
      final seat = seed % seatCount;
      final table = [for (var s = 0; s < seatCount; s++) s == seat ? v : base];
      final standings = Arena.playTable(seed, table);
      wins += standings.wins[seat];
      score += standings.totals[seat];
    }
    print('${v.name.padRight(14)} ${(100 * wins / games).toStringAsFixed(1).padLeft(6)}% '
        '${(score / games).toStringAsFixed(1).padLeft(11)}');
  }
}
