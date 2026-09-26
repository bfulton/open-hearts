/// A longer chaos walk than CI's forty seeds, and sealed ones — the
/// verifiable deal run for real, a minute or two a seed:
///
///     cd packages/table && dart run tool/chaos.dart --seeds 250 --sealed 6
///     dart run tool/chaos.dart --seeds 0 --sealed-only 1,2,3
///
/// The second walks just the sealed seeds named — the ones a longer
/// walk said broke, again after a fix, without the hour in between.
///
/// Prints every broken invariant with the faults that led there, and
/// exits non-zero if there was one.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';

int _intArg(List<String> args, String name, int fallback) {
  final flag = '--$name';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == flag && i + 1 < args.length) return int.tryParse(args[i + 1]) ?? fallback;
    if (args[i].startsWith('$flag=')) return int.tryParse(args[i].substring(flag.length + 1)) ?? fallback;
  }
  return fallback;
}

Future<void> main(List<String> args) async {
  final seeds = _intArg(args, 'seeds', 250);
  var sealedSeeds = List.generate(_intArg(args, 'sealed', 0), (i) => i);
  final only = args.indexOf('--sealed-only');
  if (only >= 0 && only + 1 < args.length) sealedSeeds = [for (final s in args[only + 1].split(',')) int.parse(s)];
  final sealed = sealedSeeds.length;
  final crypto = sealed > 0 ? await DealCrypto.load() : null;
  final started = DateTime.now();
  var failed = 0;
  for (var seed = 0; seed < seeds; seed++) {
    final why = walkChaos(seed);
    if (why != null) {
      failed++;
      print('seed $seed: $why');
    } else if ((seed + 1) % 50 == 0) {
      print('${seed + 1} seeds walked');
    }
  }
  for (final seed in sealedSeeds) {
    final why = walkChaos(seed, crypto: crypto);
    print(why == null ? 'sealed seed $seed held' : 'sealed seed $seed: $why');
    if (why != null) failed++;
  }
  final took = DateTime.now().difference(started).inSeconds;
  print('$seeds seeds and $sealed sealed in $took s: ${failed == 0 ? 'every invariant held' : '$failed broke one'}');
  exit(failed == 0 ? 0 : 1);
}
