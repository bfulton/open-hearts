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
    // Checked on arrival; what opens the card is the tokens alone.
    final bare = [for (final t in tokens) DealCrypto.tokenOf(t)];
    final card = d.unmask([...sharePks, ...pks.skip(1)], bare, masked);
    expect(card, 7);

    // The same card the whole key would have opened, and one share on
    // its own opens nothing.
    final whole = [for (var i = 0; i < 4; i++) DealCrypto.tokenOf(d.revealToken(secrets[i], masked, seed(70 + i)))];
    expect(d.unmask(pks, whole, masked), card, reason: 'by a key nobody held');
    expect(d.unmask([sharePks[0], ...pks.skip(1)], [bare[0], ...bare.skip(2)], masked), isNull);
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
    // Each seat's tokens for the whole deck in one batch, with one
    // argument for the lot — which is how a hand does it — and the
    // batch's tokens are the ones the single call makes.
    final batches = [for (var i = 0; i < 4; i++) d.revealTokens(secrets[i], deck, seed(40 + i))];
    for (var i = 0; i < 4; i++) {
      expect(d.verifyTokens(pks[i], deck, batches[i]), isTrue, reason: 'seat $i\'s batch checks');
      expect(batches[i].length, tokensBytes(deckSize));
    }
    final bent = Uint8List.fromList(batches[0])..[7 * pointBytes] ^= 1;
    expect(d.verifyTokens(pks[0], deck, bent), isFalse, reason: 'a bent token fails the batch');
    expect(d.verifyTokens(pks[1], deck, batches[0]), isFalse, reason: 'not that seat\'s batch');

    final seen = <int>{};
    for (var c = 0; c < deckSize; c++) {
      final masked = maskedAt(deck, c);
      final proved = [for (var i = 0; i < 4; i++) d.revealToken(secrets[i], masked, seed(40 + i))];
      final tokens = <Uint8List>[];
      for (var i = 0; i < 4; i++) {
        expect(d.verifyToken(pks[i], masked, proved[i]), isTrue);
        final fromBatch = Uint8List.sublistView(batches[i], c * pointBytes, (c + 1) * pointBytes);
        expect(DealCrypto.tokenOf(proved[i]), fromBatch, reason: 'seat $i, card $c: one token, two ways');
        tokens.add(fromBatch);
      }
      final card = d.unmask(pks, tokens, masked);
      expect(card, isNotNull);
      expect(seen.add(card!), isTrue, reason: 'card $card dealt twice');
      expect(d.unmask(pks.sublist(0, 3), tokens.sublist(0, 3), masked), isNull, reason: 'three tokens open nothing');
      if (c == 0) {
        // A token for another position opens nothing, or the wrong
        // thing: opening is addition, so what guards it is the check
        // the token passed on arrival.
        final wrong = [...tokens.sublist(0, 3), Uint8List.sublistView(batches[3], pointBytes, 2 * pointBytes)];
        expect(d.unmask(pks, wrong, masked), isNot(card));
      }
    }
    expect(seen.length, deckSize);

    // A token sealed to seat 1, with the argument that it is the token
    // seat 0 owes for that card. Seat 1 alone opens it; anybody checks
    // it (docs/explanation/fair-deal.md).
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

  test('any two of a jury open a card, and a juror arriving later is given a share', () async {
    final d = await DealCrypto.load();
    final secrets = [for (var i = 0; i < 4; i++) seed(i)];
    final pks = [for (final s in secrets) d.keygen(s)];
    final deck = d.initialDeck(d.aggregate(pks));
    final masked = maskedAt(deck, 7);

    // The card the whole key would open, for comparison.
    final whole = [for (var i = 0; i < 4; i++) DealCrypto.tokenOf(d.revealToken(secrets[i], masked, seed(60 + i)))];
    final card = d.unmask(pks, whole, masked);
    expect(card, isNotNull);

    // Seat 0's key in six shares, any two of which answer.
    const n = 6;
    final shares = d.splitThreshold(secrets[0], n: n, t: 2, seed: seed(80));
    expect(shares.length, n * scalarBytes);
    Uint8List share(int i) => Uint8List.sublistView(shares, (i - 1) * scalarBytes, i * scalarBytes);
    final shareKeys = {for (var i = 1; i <= n; i++) i: d.shareKey(share(i))};

    /// The card as the jurors at [have] open it, with each scaled
    /// token checked against a key anybody can work out.
    int? open(List<int> have, Uint8List Function(int) shareOf, Map<int, Uint8List> keys) {
      final tokens = <Uint8List>[];
      final against = <Uint8List>[];
      for (final i in have) {
        final coefficient = d.lagrange(have, i);
        final scaled = d.scalarMul(shareOf(i), coefficient);
        final token = d.shareToken(scaled, masked, seed(90 + i));
        final key = d.pointScale(keys[i]!, coefficient);
        expect(d.verifyToken(key, masked, token), isTrue, reason: 'juror $i\'s scaled token checks');
        tokens.add(DealCrypto.tokenOf(token));
        against.add(key);
      }
      for (var i = 1; i < 4; i++) {
        tokens.add(DealCrypto.tokenOf(d.revealToken(secrets[i], masked, seed(70 + i))));
        against.add(pks[i]);
      }
      return d.unmask(against, tokens, masked);
    }

    for (final pair in [
      [1, 2],
      [2, 5],
      [3, 6],
    ]) {
      expect(open(pair, share, shareKeys), card, reason: 'shares $pair open it');
    }
    expect(open([1, 3, 5], share, shareKeys), card, reason: 'more than two is the same card');
    expect(open([4], share, shareKeys), isNot(card), reason: 'one share opens nothing');

    // A juror arriving later is given share seven, made by two
    // holders out of their own: each sends what its share is worth
    // towards seven, and the newcomer adds them up. Neither of them
    // ever holds the key.
    final from = [2, 5];
    final seventh = d.scalarSum([for (final i in from) d.scalarMul(share(i), d.lagrange(from, i, at: 7))]);
    Uint8List wider(int i) => i == 7 ? seventh : share(i);
    final widerKeys = {...shareKeys, 7: d.shareKey(seventh)};
    for (final pair in [
      [7, 1],
      [3, 7],
    ]) {
      expect(open(pair, wider, widerKeys), card, reason: "the newcomer's share answers beside $pair");
    }
  });

  test('a secret in byte shares: any two rebuild it, and a newcomer is given one', () async {
    final d = await DealCrypto.load();
    final secret = seed(11);
    const n = 6;
    final shares = d.shareBytes(secret, n: n, t: 2, seed: seed(12));
    expect(shares.length, n * secret.length);
    Uint8List share(Uint8List from, int i) =>
        Uint8List.sublistView(from, (i - 1) * secret.length, i * secret.length);

    // No share is the secret, and no two are alike.
    for (var i = 1; i <= n; i++) {
      expect(share(shares, i), isNot(secret));
      for (var j = i + 1; j <= n; j++) {
        expect(share(shares, i), isNot(share(shares, j)));
      }
    }

    /// Whoever answers, each scaled by what its share is worth among
    /// them, summed.
    Uint8List rebuild(List<int> have, Uint8List from, {int at = 0}) =>
        d.bytesSum([for (final i in have) d.bytesScale(share(from, i), d.bytesLagrange(have, i, at: at))]);

    for (final pair in [
      [1, 2],
      [2, 5],
      [3, 6],
    ]) {
      expect(rebuild(pair, shares), secret, reason: 'shares $pair rebuild it');
    }
    expect(rebuild([1, 3, 5], shares), secret, reason: 'more than two is the same secret');
    expect(rebuild([4], shares), isNot(secret), reason: 'one share alone is not the secret');

    // A juror arriving later is given share seven by two holders,
    // neither of which ever holds the secret.
    final seventh = rebuild([2, 5], shares, at: 7);
    final wider = Uint8List.fromList([...shares, ...seventh]);
    for (final pair in [
      [7, 1],
      [3, 7],
    ]) {
      expect(rebuild(pair, wider), secret, reason: "the newcomer's share answers beside $pair");
    }

    // A threshold of three needs three.
    final three = d.shareBytes(secret, n: n, t: 3, seed: seed(13));
    expect(rebuild([1, 2], three), isNot(secret));
    expect(rebuild([1, 2, 4], three), secret);
  });
}
