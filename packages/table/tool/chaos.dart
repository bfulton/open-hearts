/// A longer chaos walk than CI's forty seeds, and sealed ones — the
/// verifiable deal run for real
/// (packages/table_sim/lib/src/chaos_walk.dart):
///
///     cd packages/table && dart run tool/chaos.dart --seeds 250 --sealed 6
///     dart run tool/chaos.dart --seeds 0 --sealed-only 1,2,3
///     dart run tool/chaos.dart --seeds 0 --sealed 14 --workers
///     dart run tool/chaos.dart --seeds 0 --sealed-only 3 --traces
///
/// The second walks just the sealed seeds named — the ones a longer
/// walk said broke, again after a fix, without the hour in between. The
/// third has every device make the deal's slow calls in a worker that
/// takes a browser's time over them, as the app does (packages/deal,
/// work.dart), where otherwise they take none. `--tally` counts what
/// the walks did: how games ended, how seats were given up, the faults
/// thrown.
///
/// Prints every broken invariant with the faults that led there, and
/// exits non-zero if there was one.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/args.dart';
import 'package:table_sim/table_sim.dart';

Future<void> main(List<String> args) async {
  final seeds = intArg(args, 'seeds', 250);
  final sealedSeeds = intsArg(args, 'sealed-only', List.generate(intArg(args, 'sealed', 0), (i) => i));
  final crypto = sealedSeeds.isNotEmpty ? await DealCrypto.load() : null;
  final workers = flagArg(args, 'workers');
  final traces = flagArg(args, 'traces');
  final tally = flagArg(args, 'tally') ? <String, int>{} : null;
  final started = DateTime.now();
  var failed = 0;
  for (var seed = 0; seed < seeds; seed++) {
    final why = walkChaos(seed, traces: traces, tally: tally);
    if (why != null) {
      failed++;
      print('seed $seed: $why');
    } else if ((seed + 1) % 50 == 0) {
      print('${seed + 1} seeds walked');
    }
  }
  for (final seed in sealedSeeds) {
    final why = walkChaos(seed, crypto: crypto, workers: workers, traces: traces, tally: tally);
    print(why == null ? 'sealed seed $seed held' : 'sealed seed $seed: $why');
    if (why != null) failed++;
  }
  if (tally != null) {
    for (final e in tally.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      print('  ${e.key}: ${e.value}');
    }
  }
  final took = DateTime.now().difference(started).inSeconds;
  print('$seeds seeds and ${sealedSeeds.length} sealed in $took s: ${failed == 0 ? 'every invariant held' : '$failed broke one'}');
  exit(failed == 0 ? 0 : 1);
}
