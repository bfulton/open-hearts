/// Random walks through the departure matrix: forty seeds on every
/// commit, the first eight of them in the quick loop as well
/// (`dart test -x slow`). The walk and its invariants live in
/// lib/src/sim/chaos_walk.dart; `dart run tool/chaos.dart --seeds 250
/// --sealed 6` walks further, the verifiable deal run for real, and
/// chaos_sealed_test.dart runs a few sealed walks.
library;

import 'package:table/src/sim/sim.dart';
import 'package:test/test.dart';

void main() {
  for (var seed = 0; seed < 40; seed++) {
    test('chaos $seed', () => expect(walkChaos(seed), isNull), tags: seed < 8 ? null : 'slow');
  }
}
