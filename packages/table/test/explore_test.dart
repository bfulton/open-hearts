/// Every one-event change to two short sealed games: a hand played
/// through, and one a person leaves during the pass of, their hand
/// opened from the escrow (packages/table_sim/lib/src/explore.dart,
/// `tool/explore.dart` for the rest).
@Tags(['slow'])
library;

import 'package:deal/deal.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());
  for (final name in ['deal', 'pass']) {
    test('every one-event change to "$name" holds', () {
      final s = Scenario.named(name)!;
      final broke = <String>[];
      final sends = sendsOf(s, crypto);
      expect(sends, isNotEmpty);
      for (var k = 0; k < sends.length; k++) {
        for (final change in Change.values) {
          final why = exploreOne(s, crypto, k, change);
          if (why != null) broke.add('$k $why');
        }
      }
      expect(broke, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
