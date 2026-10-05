/// Sealed walks drawing from nine strangers rather than four, at seeds
/// that exercise a verifier reading a hand's juries in another order
/// than the table, a hand whose draws arrive out of order (with jurors
/// let go of and summoned again, too), and an ending judged by jurors
/// out of reach (`tool/chaos.dart --jurors 9`, docs/07-states.md). A
/// file of their own, since a sealed walk takes a minute or two and
/// the tests of one file run one after another.
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
