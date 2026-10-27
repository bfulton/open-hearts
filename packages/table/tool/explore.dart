/// Every one-event change to a short sealed game, one run each
/// (packages/table_sim/lib/src/explore.dart):
///
///     cd packages/table && dart run tool/explore.dart --scenario deal
///     dart run tool/explore.dart --scenario leave --changes drop,late --shard 1/4 --first
///     dart run tool/explore.dart --scenario pass --census
///     dart run tool/explore.dart --scenario pass --at 41 --changes late
///
/// `--census` lists the events the scenario sends and stops. `--at n`
/// runs the one change to event n, with every side's trace. Prints what
/// broke in every run that broke something, and exits non-zero if one
/// did.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:engine/args.dart';
import 'package:table_sim/table_sim.dart';

Future<void> main(List<String> args) async {
  final name = strArg(args, 'scenario', 'deal');
  final scenario = Scenario.named(name);
  if (scenario == null) {
    print('no scenario $name: ${Scenario.all.map((s) => '${s.name} (${s.about})').join(', ')}');
    exit(2);
  }
  final changes = [for (final c in strArg(args, 'changes', 'drop,late,twice').split(',')) Change.values.byName(c.trim())];
  final hold = intArg(args, 'hold', 3000);
  final crypto = await rememberedCrypto();
  final sends = sendsOf(scenario, crypto);
  if (flagArg(args, 'census')) {
    for (final (i, s) in sends.indexed) {
      print('$i $s');
    }
    print('${sends.length} events');
    return;
  }
  final at = optionalArg(args, 'at');
  if (at != null) {
    for (final change in changes) {
      final why = exploreOne(scenario, crypto, int.parse(at), change, holdMs: hold, traces: true);
      print('${change.name} ${sends[int.parse(at)]}: ${why ?? 'held'}');
    }
    return;
  }
  final shard = strArg(args, 'shard', '1/1').split('/').map(int.parse).toList();
  final limit = intArg(args, 'limit', sends.length);
  final first = flagArg(args, 'first');
  final started = DateTime.now();
  var runs = 0;
  var failed = 0;
  for (var k = 0; k < sends.length && k < limit; k++) {
    if (k % shard[1] != shard[0] - 1) continue;
    for (final change in changes) {
      runs++;
      final why = exploreOne(scenario, crypto, k, change, holdMs: hold);
      if (why == null) continue;
      failed++;
      print('$k $why');
      if (first) exit(1);
    }
  }
  final took = DateTime.now().difference(started).inSeconds;
  print('$name: $runs runs over ${sends.length} events in $took s: ${failed == 0 ? 'every invariant held' : '$failed broke one'}');
  exit(failed == 0 ? 0 : 1);
}
