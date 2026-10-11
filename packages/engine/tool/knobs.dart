/// What each persona setting is worth on its own.
///
///     cd packages/engine && dart run tool/knobs.dart --games 2000
///
/// Seats one bot that differs from Westley by a single setting against
/// three Westleys, rotating the seat, and reports its win rate and mean
/// score against the 25% and the score a fourth Westley would get. This
/// is how a persona gets tuned: a setting that costs several points on
/// its own has no business in a character, however apt.
library;

import 'package:engine/args.dart';
// A benchmark's entire output is its printing.
// ignore_for_file: avoid_print

import 'package:engine/engine.dart';

void main(List<String> args) {
  final games = intArg(args, 'games', 1000);
  const base = Persona.westley;
  final variants = <Persona>[
    base,
    const Persona(name: 'no shot', epithet: '', shootLoserShare: 0),
    const Persona(name: 'shot 3', epithet: '', shootLoserShare: 3),
    const Persona(
      name: 'shot 3 pass 7',
      epithet: '',
      shootLoserShare: 3,
      shootPassMaxLosers: 7,
    ),
    const Persona(name: 'shot 5', epithet: '', shootLoserShare: 5),
    const Persona(name: 'pass 4', epithet: '', shootPassMaxLosers: 4),
    const Persona(name: 'pass 7', epithet: '', shootPassMaxLosers: 7),
    const Persona(name: 'flush 2', epithet: '', flushMinSmallSpades: 2),
    const Persona(name: 'flush 3', epithet: '', flushMinSmallSpades: 3),
    const Persona(name: 'defend 3', epithet: '', moonDefenseTrigger: 3),
    const Persona(name: 'defend 6', epithet: '', moonDefenseTrigger: 6),
    const Persona(name: 'defend 8', epithet: '', moonDefenseTrigger: 8),
    const Persona(
      name: 'pass keepQ',
      epithet: '',
      passStyle: PassStyle.keepQueen,
    ),
    const Persona(
      name: 'pass dumpQ',
      epithet: '',
      passStyle: PassStyle.dumpQueen,
    ),
    // The rungs of the ladder (Persona.at), each taken away on its own.
    const Persona(name: 'no defense', epithet: '', moonDefenseTrigger: 99),
    const Persona(name: 'no Q-alone', epithet: '', queenAloneIsSafe: false),
    const Persona(name: 'first low', epithet: '', firstTrickHigh: false),
    const Persona(name: 'no heart dump', epithet: '', dumpsHearts: false),
    const Persona(name: 'short wt 3', epithet: '', shortSuitWeight: 3),
    const Persona(name: 'no flush', epithet: '', flushMinSmallSpades: 99),
    // The bottom rungs: what a first game does not do yet.
    const Persona(name: 'no shape', epithet: '', passesShape: false),
    const Persona(name: 'no ducking', epithet: '', ducksHigh: false),
    const Persona(name: 'no take high', epithet: '', takesHigh: false),
    const Persona(name: 'no discards', epithet: '', discardsPoints: false),
  ];
  print('$games games each, one variant against three Westleys\n');
  print(
    '${'variant'.padRight(14)} ${'wins'.padLeft(7)} ${'mean score'.padLeft(11)}',
  );
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
    print(
      '${v.name.padRight(14)} ${(100 * wins / games).toStringAsFixed(1).padLeft(6)}% '
      '${(score / games).toStringAsFixed(1).padLeft(11)}',
    );
  }
}
