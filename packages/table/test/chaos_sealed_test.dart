/// Sealed walks: the verifiable deal run for real, the house holding
/// the bot seats, with its restarts and a slow line among the faults,
/// and a seat that lies (`tool/chaos.dart --sealed`). A file of their
/// own, since a sealed walk takes seconds with the deal's answers kept
/// (package:deal/memo.dart) and the tests of one file run one after
/// another.
@Tags(['slow'])
library;

import 'package:deal/deal.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());
  for (var seed = 0; seed < 12; seed++) {
    test('sealed chaos $seed', () => expect(walkChaos(seed, crypto: crypto), isNull), timeout: const Timeout(Duration(minutes: 10)));
  }
  test('sealed chaos with the deal\'s slow calls on a worker', () => expect(walkChaos(3, crypto: crypto, workers: true), isNull),
      timeout: const Timeout(Duration(minutes: 10)));
}
