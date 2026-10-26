/// The games kept in packages/table/test/fixtures, as the simulator
/// plays them: what the tool that wrote them and the test that reads
/// them again both build.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'scripted_human.dart';
import 'sim_table.dart';

/// The names the game of three was kept with.
const threeNames = {0: 'Ada', 1: 'Bao', 2: 'Cy'};

/// Three people and a bot a juror holds; one person leaves in the second
/// trick, and the hand is finished with the seat's cards opened from
/// escrow. Played out and not stopped. Everything in it comes from fixed
/// seeds — the simulator's signers too — so the same library plays the
/// same record, byte for byte: packages/table's tool/kept_records.dart
/// wrote it once, and test/kept_records_test.dart plays it again. At
/// the clocks it was kept at, the first builds' standard, which its
/// spec says by saying none (`TableTiming.unsaid`).
SimTable threeAndALeaver(DealCrypto crypto) {
  final three = SimTable(humans: 3, seed: 5, crypto: crypto, jurors: jurySize + 2, target: 1, timing: TableTiming.unsaid);
  three.start();
  final a = three.people.first.client;
  if (!three.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1, limitMs: 10 * 60 * 1000)) {
    throw StateError('the game of three did not reach play');
  }
  three.people[2].depart(Exit.leave);
  if (!three.clock.runUntil(() => a.done, limitMs: 30 * 60 * 1000)) throw StateError('the game of three did not finish: ${a.describe()}');
  three.clock.advance(20000);
  return three;
}
