/// A longer chaos walk than CI's forty seeds, and sealed ones — the
/// verifiable deal run for real, a minute or two a seed:
///
///     cd packages/table && dart run tool/chaos.dart --seeds 250 --sealed 6
///     dart run tool/chaos.dart --seeds 0 --sealed-only 1,2,3
///     dart run tool/chaos.dart --seeds 250 --sealed 14 --structure
///     dart run tool/chaos.dart --seeds 100 --sealed 14 --jurors 9 --sweep
///
/// The second walks just the sealed seeds named — the ones a longer
/// walk said broke, again after a fix, without the hour in between.
/// The third also reads every side against the state machines as it
/// walks (docs/07-states.md, "Measured"). The fourth draws from more
/// strangers than a jury, each letting go of the table once it has
/// served, as the duty does, and summoned again later.
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
  // `--structure`: every five seconds of each walk, what every side
  // waits for, read against who can end it (lib/src/sim/structure.dart).
  // Measures; decides nothing.
  final measure = args.contains('--structure');
  // `--jurors N --sweep`: more strangers than a jury, each letting go
  // of the table once it has served and summoned again later, as the
  // duty does — and what any of them would have said about a hand
  // from before its summons, by kind.
  final jurors = _intArg(args, 'jurors', 4);
  final sweep = args.contains('--sweep');
  final saidBefore = <String, int>{};
  void jurorLog(String line) {
    final at = line.indexOf('over before this side was summoned: ');
    if (at < 0) return;
    final kind = line.substring(at + 'over before this side was summoned: '.length).split(' ').first;
    saidBefore[kind] = (saidBefore[kind] ?? 0) + 1;
  }

  final totals = <String, int>{};
  final withAny = <String, int>{};
  final endedWith = <String, int>{};
  final endedOnline = <String, int>{};
  StructureLog? log() => measure ? StructureLog() : null;
  void report(String name, StructureLog? s) {
    if (s == null || s.seen.isEmpty) return;
    for (final e in s.counts.entries) {
      totals[e.key.name] = (totals[e.key.name] ?? 0) + e.value;
      withAny[e.key.name] = (withAny[e.key.name] ?? 0) + 1;
    }
    for (final kind in s.standing.keys) {
      endedWith[kind.name] = (endedWith[kind.name] ?? 0) + 1;
    }
    for (final kind in s.standingOnline.keys) {
      endedOnline[kind.name] = (endedOnline[kind.name] ?? 0) + 1;
    }
    print('$name: ${s.counts.entries.map((e) => '${e.key.name} ${e.value}').join(', ')}'
        '${s.standing.isEmpty ? '' : '; at the end ${s.standing.entries.map((e) => '${e.key.name} ${e.value}').join(', ')}'}');
    final shown = <String>{};
    for (final e in s.seen.values) {
      if (!shown.add(e.finding.what.name)) continue;
      print('  first ${e.finding} (${e.first} to ${e.last} ms)');
    }
  }

  for (var seed = 0; seed < seeds; seed++) {
    final s = log();
    final why = walkChaos(seed, structure: s, jurors: jurors, sweep: sweep, jurorLog: sweep ? jurorLog : null);
    report('seed $seed', s);
    if (why != null) {
      failed++;
      print('seed $seed: $why');
    } else if ((seed + 1) % 50 == 0) {
      print('${seed + 1} seeds walked');
    }
  }
  for (final seed in sealedSeeds) {
    final s = log();
    final why = walkChaos(seed, crypto: crypto, structure: s, jurors: jurors, sweep: sweep, jurorLog: sweep ? jurorLog : null);
    report('sealed seed $seed', s);
    print(why == null ? 'sealed seed $seed held' : 'sealed seed $seed: $why');
    if (why != null) failed++;
  }
  if (measure) {
    print('structure: ${totals.isEmpty ? 'nothing found' : totals.entries.map((e) => '${e.key} ${e.value} in ${withAny[e.key]} walk(s), '
        'still there at the end of ${endedWith[e.key] ?? 0} (${endedOnline[e.key] ?? 0} among sides online)').join('; ')}');
  }
  if (sweep) print('said about a hand before the summons: ${saidBefore.isEmpty ? 'nothing' : saidBefore}');
  final took = DateTime.now().difference(started).inSeconds;
  print('$seeds seeds and $sealed sealed in $took s: ${failed == 0 ? 'every invariant held' : '$failed broke one'}');
  exit(failed == 0 ? 0 : 1);
}
