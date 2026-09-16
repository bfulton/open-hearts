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

  test('a departed seat\'s card opens from its key\'s two shares, the key never rebuilt', () {
    final secrets = [for (var i = 1; i <= 4; i++) seed(i)];
    final pks = [for (final s in secrets) d.keygen(s)];
    final deck = d.initialDeck(d.aggregate(pks));
    final masked = Uint8List.sublistView(deck, 7 * maskedBytes, 8 * maskedBytes);

    // Seat 0 is gone; its key was split in two at the deal.
    final shares = d.split(secrets[0], seed(60));
    expect(shares.length, 2 * scalarBytes);
    final a = Uint8List.sublistView(shares, 0, scalarBytes);
    final b = Uint8List.sublistView(shares, scalarBytes);
    final sharePks = [d.shareKey(a), d.shareKey(b)];
    expect(d.aggregate(sharePks), pks[0], reason: "the shares' keys add to the seat's key");

    // Five tokens where there were four: the two shares, and the three
    // seats still here.
    final tokens = [
      d.shareToken(a, masked, seed(61)),
      d.shareToken(b, masked, seed(62)),
      for (var i = 1; i < 4; i++) d.revealToken(secrets[i], masked, seed(63 + i)),
    ];
    expect(d.verifyToken(sharePks[0], masked, tokens[0]), isTrue);
    expect(d.verifyToken(pks[0], masked, tokens[0]), isFalse, reason: "not against the seat's whole key");
    final card = d.unmask([...sharePks, ...pks.skip(1)], tokens, masked);
    expect(card, 7);

    // The same card the whole key would have opened, and one share on
    // its own opens nothing.
    final whole = [for (var i = 0; i < 4; i++) d.revealToken(secrets[i], masked, seed(70 + i))];
    expect(d.unmask(pks, whole, masked), card, reason: 'by a key nobody held');
    expect(d.unmask([sharePks[0], ...pks.skip(1)], [tokens[0], ...tokens.skip(2)], masked), isNull);
  });

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

    // A token sealed to seat 1, with the argument that it is the token
    // seat 0 owes for that card. Seat 1 alone opens it; anybody checks
    // it (docs/03-fair-deal.md).
    final masked0 = maskedAt(deck, 0);
    final token = d.revealToken(secrets[0], masked0, seed(50));
    final sealed = d.seal(secrets[0], pks[1], masked0, seed(51));
    expect(sealed, hasLength(sealedBytes + sealProofBytes));
    expect(d.open(secrets[1], sealed), token.sublist(0, pointBytes));
    expect(d.open(secrets[2], sealed), isNot(token.sublist(0, pointBytes)));
    expect(d.verifySeal(pks[0], pks[1], masked0, sealed), isTrue);
    expect(d.verifySeal(pks[2], pks[1], masked0, sealed), isFalse, reason: 'not another seat\'s token');
    expect(d.verifySeal(pks[0], pks[2], masked0, sealed), isFalse, reason: 'not sealed to another seat');
    expect(d.verifySeal(pks[0], pks[1], maskedAt(deck, 1), sealed), isFalse, reason: 'not another card');
    for (final i in [0, sealedBytes - 1, sealedBytes, sealed.length - 1]) {
      final bent = Uint8List.fromList(sealed)..[i] ^= 1;
      expect(d.verifySeal(pks[0], pks[1], masked0, bent), isFalse, reason: 'a bent byte at $i');
    }
    expect(d.sharedSecret(secrets[0], pks[1]), d.sharedSecret(secrets[1], pks[0]));
    expect(d.sharedSecret(secrets[0], pks[2]), isNot(d.sharedSecret(secrets[0], pks[1])));
  });
}
