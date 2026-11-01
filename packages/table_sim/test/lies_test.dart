/// The simulator's lies, each the lie it says it is.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deal/deal.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  test('a pass sealed to nothing has the shape of an honest one, and only the argument beside each seal refuses it', () async {
    final d = await rememberedCrypto();
    final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), const BotDealSeat(), const BotDealSeat()];
    Uint8List wrap(String other) => Uint8List.fromList(sha256.convert(utf8.encode(other)).bytes);
    final all = [
      for (var s = 0; s < 2; s++)
        DealSession(d,
            tableId: 'T',
            tableSeed: 1,
            hand: 0,
            seats: seats,
            leadCard: 0,
            mySeat: s,
            myKey: (seats[s] as HumanDealSeat).key,
            wrap: wrap,
            random: Random(s)),
    ];
    for (final (s, x) in all.indexed) {
      expect(all[1 - s].acceptKeys(x.myKeys()!), isTrue);
    }
    for (final (s, x) in all.indexed) {
      expect(all[1 - s].acceptShuffle(x.myShuffle()!), isTrue);
    }
    for (final (s, x) in all.indexed) {
      expect(all[1 - s].acceptTokens(x.myTokens()!), isTrue);
    }
    final pass = all[0].passMessage(1, [0, 1, 2])!;
    expect(all[1].verifyPass(pass), isTrue);

    final lie = {...pass, 'sealed': Lie.seal.sealedPass([for (final s in pass['sealed']! as List) s as String], Random(0))};
    for (final s in lie['sealed']! as List) {
      expect(base64.decode(s as String), hasLength(sealedBytes + sealProofBytes), reason: 'each the size an honest seal is');
    }
    expect(all[1].verifyPass(lie), isFalse);
  });
}
