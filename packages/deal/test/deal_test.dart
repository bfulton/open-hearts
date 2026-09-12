/// The deal's primitives over FFI: a whole deal among four, every card
/// opened once, a token sealed to one seat.
library;

import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:test/test.dart';

Uint8List seed(int i) => Uint8List(32)..[0] = i..[31] = 7;

void main() {
  late DealCrypto d;
  setUpAll(() async => d = await DealCrypto.load());

  test('four seats deal fifty-two cards, each opened once, none without every token', () {
    final secrets = [for (var i = 1; i <= 4; i++) seed(i)];
    final pks = [for (final s in secrets) d.keygen(s)];
    for (var i = 0; i < 4; i++) {
      final proof = d.keyProof(secrets[i], Uint8List.fromList('seat$i'.codeUnits), seed(9));
      expect(proof.length, keyProofBytes);
      expect(d.verifyKey(pks[i], Uint8List.fromList('seat$i'.codeUnits), proof), isTrue);
      expect(d.verifyKey(pks[i], Uint8List.fromList('other'.codeUnits), proof), isFalse);
    }
    final joint = d.aggregate(pks);
    var deck = d.initialDeck(joint);
    expect(deck.length, deckBytes);
    expect(d.initialDeck(joint), deck, reason: 'the same for everyone');
    for (var s = 0; s < 4; s++) {
      final r = d.shuffle(joint, deck, seed(20 + s));
      expect(d.verifyShuffle(joint, deck, r.deck, r.proof), isTrue);
      expect(d.verifyShuffle(joint, r.deck, deck, r.proof), isFalse);
      deck = r.deck;
    }
    final seen = <int>{};
    for (var c = 0; c < deckSize; c++) {
      final masked = maskedAt(deck, c);
      final tokens = [for (var i = 0; i < 4; i++) d.revealToken(secrets[i], masked, seed(40 + i))];
      for (var i = 0; i < 4; i++) {
        expect(d.verifyToken(pks[i], masked, tokens[i]), isTrue);
      }
      final card = d.unmask(pks, tokens, masked);
      expect(card, isNotNull);
      expect(seen.add(card!), isTrue, reason: 'card $card dealt twice');
      expect(d.unmask(pks, tokens, masked, verified: true), card, reason: 'unchecked, the same card');
      expect(d.unmask(pks.sublist(0, 3), tokens.sublist(0, 3), masked), isNull, reason: 'three tokens open nothing');
      if (c == 0) {
        // A token for another position: caught when checked; combined
        // blindly it opens nothing, or the wrong thing, which is why
        // unchecked is only for tokens checked on arrival.
        final wrong = [...tokens.sublist(0, 3), d.revealToken(secrets[3], maskedAt(deck, 1), seed(41))];
        expect(d.unmask(pks, wrong, masked), isNull);
        expect(d.unmask(pks, wrong, masked, verified: true), isNot(card));
      }
    }
    expect(seen.length, deckSize);

    final token = d.revealToken(secrets[0], maskedAt(deck, 0), seed(50));
    final sealed = d.seal(pks[1], token, seed(51));
    expect(d.open(secrets[1], sealed), token.sublist(0, pointBytes));
    expect(d.open(secrets[2], sealed), isNot(token.sublist(0, pointBytes)));
    expect(d.sharedSecret(secrets[0], pks[1]), d.sharedSecret(secrets[1], pks[0]));
    expect(d.sharedSecret(secrets[0], pks[2]), isNot(d.sharedSecret(secrets[0], pks[1])));
  });
}
