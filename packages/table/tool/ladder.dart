/// Calibrates the strength ladder: every persona at every level, seated
/// four at a time at random, and rated from the pairwise results the
/// way a live table would score them (lower total wins the pair).
///
///     cd packages/table && dart run tool/ladder.dart --tables 20000
///
/// The fit is Bradley–Terry (the model Glicko's expected score is), by
/// the minorisation–maximisation iteration, on the same 400-points-
/// per-decade scale as a rating, anchored so the top level's mean is
/// 1500. Glicko itself would do, but its deviation floor keeps a rating
/// wandering by fifty points however many games it has seen; the fit
/// tightens with every table. Prints each level's mean over the
/// personas with its standard error, every identity, and the `priors`
/// line to paste into persona.dart.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:math';

import 'package:engine/args.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

void main(List<String> args) {
  final tables = intArg(args, 'tables', 20000);
  final all = Persona.all;
  final index = {for (var i = 0; i < all.length; i++) all[i].id: i};
  final n = all.length;
  final rng = Random(11);
  // Pairwise score and count between identities, and games per identity.
  final score = List.generate(n, (_) => List.filled(n, 0.0));
  final meetings = List.generate(n, (_) => List.filled(n, 0));
  final games = List.filled(n, 0);
  for (var t = 0; t < tables; t++) {
    // Four distinct names, at levels drawn near one centre, so every
    // rung meets its neighbours often and the ends now and then.
    final names = List.of(Persona.roster)..shuffle(rng);
    final centre = rng.nextInt(Persona.levels);
    final table = [
      for (var s = 0; s < seatCount; s++)
        names[s].at((centre + rng.nextInt(7) - 3).clamp(0, Persona.top)),
    ];
    final totals = Arena.playTable(5000 + t, table).totals;
    for (var a = 0; a < seatCount; a++) {
      final i = index[table[a].id]!;
      games[i]++;
      for (var b = 0; b < seatCount; b++) {
        if (a == b) continue;
        final j = index[table[b].id]!;
        meetings[i][j]++;
        score[i][j] += pairwise(totals[a], [totals[b]]).first;
      }
    }
  }

  // Bradley–Terry by MM (Hunter 2004): p_i ← w_i / Σ_j n_ij / (p_i + p_j).
  final wins = [for (var i = 0; i < n; i++) score[i].reduce((a, b) => a + b)];
  var p = List.filled(n, 1.0);
  for (var iteration = 0; iteration < 5000; iteration++) {
    final next = List.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      var denominator = 0.0;
      for (var j = 0; j < n; j++) {
        if (meetings[i][j] > 0) denominator += meetings[i][j] / (p[i] + p[j]);
      }
      next[i] = wins[i] / denominator;
    }
    final mean = exp(next.map(log).reduce((a, b) => a + b) / n);
    for (var i = 0; i < n; i++) {
      next[i] /= mean;
    }
    var change = 0.0;
    for (var i = 0; i < n; i++) {
      change = max(change, (log(next[i]) - log(p[i])).abs());
    }
    p = next;
    if (change < 1e-9) break;
  }
  const perDecade = 400.0;
  final raw = [for (var i = 0; i < n; i++) perDecade * log(p[i]) / ln10];
  // The standard error of a strength, from the Fisher information of
  // the pairs it has played.
  final se = [
    for (var i = 0; i < n; i++)
      () {
        var info = 0.0;
        for (var j = 0; j < n; j++) {
          if (meetings[i][j] > 0) {
            info += meetings[i][j] * p[i] * p[j] / pow(p[i] + p[j], 2);
          }
        }
        return perDecade / ln10 / sqrt(info);
      }(),
  ];

  double levelMean(List<double> xs, int level) {
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i < n; i++) {
      if (all[i].level == level) {
        sum += xs[i];
        count++;
      }
    }
    return sum / count;
  }

  final means = [for (var l = 0; l < Persona.levels; l++) levelMean(raw, l)];
  final anchor = 1500 - means[Persona.top];
  final rating = [for (final r in raw) r + anchor];
  print(
    '$tables tables among $n identities, ${games.reduce(min)}–${games.reduce(max)} games each\n',
  );
  print(
    '${'level'.padRight(6)} ${'rating'.padLeft(7)} ${'±'.padLeft(4)} ${'step'.padLeft(5)}   personas',
  );
  for (var l = Persona.top; l >= 0; l--) {
    final row = [
      for (final persona in Persona.roster)
        '${persona.name.padRight(9)}${rating[index[persona.at(l).id]!].round().toString().padLeft(5)}',
    ].join('  ');
    final err = levelMean(se, l) / sqrt(Persona.roster.length);
    final step = l == Persona.top
        ? ''
        : (means[l + 1] - means[l]).round().toString();
    print(
      '${l.toString().padRight(6)} ${(means[l] + anchor).round().toString().padLeft(7)} '
      '${err.round().toString().padLeft(4)} ${step.padLeft(5)}   $row',
    );
  }
  print(
    '\nstatic const priors = [${[for (var l = 0; l < Persona.levels; l++) (means[l] + anchor).round()].join(', ')}];',
  );
}
