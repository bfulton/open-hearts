/// Sealed walks drawing from nine strangers rather than four, each the
/// one that found something: a verifier reading a hand's juries in
/// another order than the table (seed 1), one hand sealed to two draws
/// (seed 2, and seed 3 with jurors let go of and summoned again), and
/// the walk judging an ending by jurors it could not reach (seed 4)
/// (`tool/chaos.dart --jurors 9`, docs/07-states.md). A file of their
/// own, since a sealed walk takes a minute or two and the tests of one
/// file run one after another.
library;

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());
  for (final (seed, sweep) in [(1, false), (2, false), (3, true), (4, false)]) {
    test('sealed chaos $seed, nine strangers${sweep ? ', let go and summoned again' : ''}',
        () => expect(walkChaos(seed, crypto: crypto, jurors: 9, sweep: sweep), isNull),
        timeout: const Timeout(Duration(minutes: 10)));
  }
}
