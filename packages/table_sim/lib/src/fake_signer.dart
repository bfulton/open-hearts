/// The simulator's signer, and the check that takes its signatures.
///
/// The simulator needs thousands of signatures per game and cares about
/// none of them being forgeable, so [FakeSigner] produces a hash. It
/// exercises every code path a real key does, at a thousandth of the
/// cost, and a real key never touches it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:table/table.dart';

/// A stand-in for tests: the "signature" is a hash of key and digest.
///
/// Anyone could forge it, and that is not a detail: what it hashes is
/// the signer's *public* key, which everyone at a table has. A peer
/// could sign as any other seat simply by making the hash. So the table
/// takes none — its [verify] is BIP-340 and nothing else — and making
/// one is what puts a check for them in front of [schnorrVerifier], in
/// this process: a simulation and a test make them, and nothing a
/// person runs has this package in it. Arming it here rather than at
/// each entry point is the point: an entry point can be forgotten.
class FakeSigner implements Signer {
  FakeSigner(String name) : publicKey = sha256Hex(utf8.encode('fake:$name')) {
    _takeFakes();
  }

  static const length = 32; // half a real signature, so never mistaken

  @override
  final PublicKey publicKey;

  @override
  String sign(String digestHex) => _tag(publicKey, digestHex);

  static String _tag(PublicKey key, String digestHex) =>
      sha256Hex(utf8.encode('$key|$digestHex')).substring(0, length);

  static bool check(PublicKey key, String digestHex, String sig) => _tag(key, digestHex) == sig;

  /// A hash of the two keys — anyone could compute it, as anyone could
  /// forge the signature. Symmetric, which is all the simulator needs.
  @override
  Uint8List sharedSecretWith(PublicKey other) {
    final pair = [publicKey, other]..sort();
    return Uint8List.fromList(sha256.convert(utf8.encode('fake-shared:${pair[0]}|${pair[1]}')).bytes);
  }

  @override
  Uint8List sharedXWith(PublicKey other) {
    final pair = [publicKey, other]..sort();
    return Uint8List.fromList(sha256.convert(utf8.encode('fake-shared-x:${pair[0]}|${pair[1]}')).bytes);
  }
}

/// The checks [_takeFakes] has put in place, each in front of the
/// verifier it found.
final _ours = <Function>{};

/// Puts [FakeSigner.check] in front of whatever checks a real
/// signature now, unless it is there already. A signature of a fake's
/// length goes to it and never to the curve; any other goes on as
/// before.
///
/// Each check holds the verifier it was put in front of, so a verifier
/// swapped in later — installNativeSchnorr, a test's own — is covered
/// by the next fake signer made, and one put back is put back with the
/// check that was over it.
void _takeFakes() {
  final real = schnorrVerifier;
  if (_ours.contains(real)) return;
  bool withFakes(PublicKey key, String digestHex, String signatureHex) =>
      signatureHex.length == FakeSigner.length ? FakeSigner.check(key, digestHex, signatureHex) : real(key, digestHex, signatureHex);
  _ours.add(withFakes);
  schnorrVerifier = withFakes;
}
