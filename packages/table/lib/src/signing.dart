/// Keys and signatures.
///
/// An identity is a keypair in Nostr's format — a 32-byte x-only
/// secp256k1 public key and BIP-340 Schnorr signatures — so the same key
/// signs plays at the table and presence on the relays. [Signer] is what
/// a client holds; [verify] is what everyone runs on everyone else.
///
/// The simulator needs thousands of signatures per game and cares about
/// none of them being forgeable, so [FakeSigner] produces a hash the
/// verifier recognises. It exercises every code path the real one does,
/// at a thousandth of the cost, and a real key never touches it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';

/// A public key, as 64 lowercase hex characters.
typedef PublicKey = String;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String sha256Hex(List<int> bytes) => _hex(sha256.convert(bytes).bytes);

abstract class Signer {
  PublicKey get publicKey;

  /// Signs a 32-byte digest, hex in and hex out.
  String sign(String digestHex);
}

/// Checks [signatureHex] over [digestHex] by [key]. Recognises both real
/// and fake signatures, by their length, so a simulated table and a real
/// one share every line of protocol code.
bool verify(PublicKey key, String digestHex, String signatureHex) {
  if (signatureHex.length == FakeSigner.length) {
    return FakeSigner.check(key, digestHex, signatureHex);
  }
  try {
    return schnorrVerifier(key, digestHex, signatureHex);
  } catch (_) {
    return false;
  }
}

/// How a real signature is checked. The pure-Dart `bip340` package by
/// default — 11 ms in the VM, fine for the service and the tests — and
/// on the web the app swaps in its wasm, which is two hundred times
/// faster there (measurements/sign). Set once, at startup, before any
/// event is parsed.
bool Function(PublicKey key, String digestHex, String signatureHex) schnorrVerifier = bip340.verify;

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
    return bip340.sign(_secretHex, digestHex, aux);
  }
}

/// A stand-in for tests: the "signature" is a hash of key and digest.
/// Anyone could forge it; nobody in a simulation tries to.
class FakeSigner implements Signer {
  FakeSigner(String name) : publicKey = sha256Hex(utf8.encode('fake:$name'));

  static const length = 32; // half a real signature, so never mistaken

  @override
  final PublicKey publicKey;

  @override
  String sign(String digestHex) => _tag(publicKey, digestHex);

  static String _tag(PublicKey key, String digestHex) =>
      sha256Hex(utf8.encode('$key|$digestHex')).substring(0, length);

  static bool check(PublicKey key, String digestHex, String sig) => _tag(key, digestHex) == sig;
}

/// The digest an event is signed over: SHA-256 of its canonical bytes.
String digestOf(Uint8List canonical) => sha256Hex(canonical);
