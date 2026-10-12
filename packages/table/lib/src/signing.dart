/// Keys and signatures.
///
/// An identity is a keypair in Nostr's format — a 32-byte x-only
/// secp256k1 public key and BIP-340 Schnorr signatures — so the same key
/// signs plays at the table and presence on the relays. [Signer] is what
/// a client holds; [verify] is what everyone runs on everyone else, and
/// it takes BIP-340 and nothing else. The simulator's stand-in signer,
/// and the check that takes its signatures, are the simulator's
/// (packages/table_sim).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

/// A public key, as 64 lowercase hex characters.
typedef PublicKey = String;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String sha256Hex(List<int> bytes) => _hex(sha256.convert(bytes).bytes);

abstract class Signer {
  PublicKey get publicKey;

  /// Signs a 32-byte digest, hex in and hex out.
  String sign(String digestHex);

  /// Thirty-two bytes this key shares with the holder of [other] and
  /// nobody else: the same from either end. What a seat wraps the
  /// escrow shares of its deal secret in (docs/explanation/fair-deal.md), so
  /// they can travel in the open to the seats and jurors named.
  Uint8List sharedSecretWith(PublicKey other);

  /// The x coordinate of the point this key shares with the holder of
  /// [other]: what NIP-44 (nip44.dart) makes a conversation key from,
  /// so a message sealed here opens at the other end as it would in
  /// any client that speaks it.
  Uint8List sharedXWith(PublicKey other);
}

/// Checks [signatureHex] over [digestHex] by [key], with
/// [schnorrVerifier]: false for a signature that does not hold, and for
/// anything that is not one.
bool verify(PublicKey key, String digestHex, String signatureHex) {
  try {
    return schnorrVerifier(key, digestHex, signatureHex);
  } catch (_) {
    return false;
  }
}

/// How a real signature is checked. The pure-Dart `bip340` package by
/// default, and on the web the app swaps in its wasm
/// (crypto/schnorr_wasm), the VM its cdylib (schnorr_native.dart): the
/// same k256 code compiled, which is what makes checking every event
/// of a table, several times a turn, cheap enough not to notice. Set
/// once, at startup, before any event is parsed. A process running the
/// simulator also has its fake signatures' check put in front of it
/// (packages/table_sim, `FakeSigner`).
bool Function(PublicKey key, String digestHex, String signatureHex) schnorrVerifier = bip340.verify;

/// How a real signature is made: secret, digest and thirty-two bytes of
/// auxiliary randomness, all hex, to a 128-hex signature. Swapped along
/// with the verifier.
String Function(String secretHex, String digestHex, String auxHex) schnorrSigning = bip340.sign;

/// A real key. Generated fresh, or loaded from the 32-byte secret.
class SchnorrSigner implements Signer {
  SchnorrSigner.fromSecret(this._secretHex) : publicKey = bip340.getPublicKey(_secretHex);

  factory SchnorrSigner.generate([Random? random]) {
    final rng = random ?? Random.secure();
    return SchnorrSigner.fromSecret(_hex(List.generate(32, (_) => rng.nextInt(256))));
  }

  final String _secretHex;

  @override
  final PublicKey publicKey;

  @override
  String sign(String digestHex) {
    // BIP-340 takes 32 bytes of auxiliary randomness; a signature is
    // still valid with any value, and fresh is best.
    final rng = Random.secure();
    final aux = _hex(List.generate(32, (_) => rng.nextInt(256)));
    return schnorrSigning(_secretHex, digestHex, aux);
  }

  static final _secp256k1 = ECCurve_secp256k1();

  /// Diffie–Hellman on the curve the keys already live on: the x
  /// coordinate of this secret times the other key's point, hashed.
  /// An x-only key names two points, one the negation of the other,
  /// and both give the same x when multiplied — so the two ends agree
  /// whichever of the two each secret really is.
  @override
  Uint8List sharedSecretWith(PublicKey other) =>
      Uint8List.fromList(sha256.convert([...utf8.encode('open-hearts shared secret v1|'), ...sharedXWith(other)]).bytes);

  /// Throws for what is not a key or not a secret: an x with no point
  /// on the curve, or off the field; a secret of zero or past the
  /// curve's order.
  @override
  Uint8List sharedXWith(PublicKey other) {
    final secret = BigInt.parse(_secretHex, radix: 16);
    if (secret <= BigInt.zero || secret >= _secp256k1.n) throw ArgumentError('not a secret');
    if (other.length != 64 || BigInt.parse(other, radix: 16) >= _fieldPrime) throw ArgumentError('not a key: $other');
    final point = _secp256k1.curve.decodePoint([2, ..._unhex(other)]);
    if (point == null) throw ArgumentError('not a key: $other');
    final shared = point * secret;
    if (shared == null || shared.isInfinity) throw ArgumentError('not a key: $other');
    final x = shared.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(_unhex(x));
  }

  static final _fieldPrime = BigInt.parse('fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f', radix: 16);
}

List<int> _unhex(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

/// The digest an event is signed over: SHA-256 of its canonical bytes.
String digestOf(Uint8List canonical) => sha256Hex(canonical);
