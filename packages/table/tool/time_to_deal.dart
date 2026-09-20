/// How long a sealed hand takes to deal, and what the jury's own
/// waits cost in it.
///
///     dart run tool/time_to_deal.dart
///     dart run tool/time_to_deal.dart --seeds 20 --jury 6
///
/// A sealed deal is four rounds of turns between the people and the
/// jurors holding the bot seats, and nobody sees a card until the last
/// of them settles. That wait is the whole of what a person notices
/// about the deal, so it is worth a number rather than an impression —
/// and the client holds back in two places on purpose, which is what
/// this is here to price:
///
///  - a juror will not publish its seat's keys until the hand's first
///    jury has stood still for a moment (`_juryFirmMs`), so that a
///    draw belonging before the one it read has time to arrive;
///  - a hand with bot seats waits for a jury big enough to hold them
///    (`_jurorsWaitMs`), which on a table with jurors about is over as
///    soon as the draw carries.
///
/// The simulator's clock is virtual, so these are the protocol's own
/// waits and latencies with no machine speed in them: the same seed
/// gives the same milliseconds every time.
///
/// What it found, at a jury of ten and twenty seeds: neither of those
/// two waits is what the time goes on. The deal is 6.55 s when
/// nothing goes missing, and 15.41 s — fourteen hands in twenty —
/// when a juror settles its own seat's keys and is missing the other
/// bot seat's. It then waits out `carryRepeatMs` to be sent them,
/// because the copy that went to another juror a moment earlier
/// counts as having been said. Setting the firmness wait anywhere
/// from zero to four seconds changes nothing; setting that window to
/// two seconds turns the slow hands into 8.51 s.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  final crypto = await DealCrypto.load();
  int argOf(String name, int fallback) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? int.parse(args[i + 1]) : fallback;
  }

  final seeds = argOf('seeds', 12);
  final jurors = argOf('jury', jurySize + 4);
  final took = <int>[];
  final each = <({int seed, int ms})>[];
  for (var seed = 1; seed <= seeds; seed++) {
    final t = SimTable(humans: 2, seed: seed, crypto: crypto, jurors: jurors);
    t.start();
    final dealt = t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 10 * 60 * 1000);
    if (!dealt) {
      print('seed $seed: never dealt');
      t.stop();
      continue;
    }
    took.add(t.clock.nowMs);
    each.add((seed: seed, ms: t.clock.nowMs));
    t.stop();
  }
  took.sort();
  if (took.isEmpty) {
    print('nothing dealt');
    return;
  }
  final mean = took.reduce((a, b) => a + b) / took.length;
  print('two people, two bot seats, a jury of $jurors, ${took.length} of $seeds hands dealt');
  print('  first card in ${(took.first / 1000).toStringAsFixed(2)} s at best, '
      '${(mean / 1000).toStringAsFixed(2)} s on average, '
      '${(took[took.length ~/ 2] / 1000).toStringAsFixed(2)} s in the middle, '
      '${(took.last / 1000).toStringAsFixed(2)} s at worst');
  print('  every hand, by seed: ${each.map((e) => '${e.seed}:${(e.ms / 1000).toStringAsFixed(2)}').join(' ')}');
}
