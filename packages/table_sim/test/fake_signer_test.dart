/// The simulator's fake signatures: taken where a fake signer has been
/// made, checked in front of the curve and never by it, and kept in
/// front of whatever verifier the process swaps in.
library;

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  const key = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

  test('a fake signature counts once a fake signer is made, and never reaches the curve', () {
    // What a FakeSigner signs with is a hash of its own public key, and
    // a table's every key is public. Anyone at one could sign as anyone
    // else at it, which is why the check is the simulator's alone.
    final before = schnorrVerifier;
    var asked = 0;
    schnorrVerifier = (k, d, x) {
      asked++;
      return before(k, d, x);
    };
    try {
      final digest = sha256Hex([7, 7, 7]);
      final forged = sha256Hex('$key|$digest'.codeUnits).substring(0, FakeSigner.length);
      expect(verify(key, digest, forged), isFalse, reason: 'no fake signer here yet, so no fake signature');
      expect(asked, 1, reason: 'it went to the curve, which refused it');
      final sim = FakeSigner('seat0');
      expect(verify(sim.publicKey, digest, sim.sign(digest)), isTrue, reason: 'making one is what arms it');
      expect(verify(key, digest, forged), isTrue, reason: 'forged from a public key, and taken: why only a simulation has this');
      expect(verify(sim.publicKey, digest, '0' * FakeSigner.length), isFalse, reason: 'a wrong one of a fake\'s length is refused');
      expect(asked, 1, reason: 'and none of them reaches the curve');
      final real = SchnorrSigner.generate();
      expect(verify(real.publicKey, digest, real.sign(digest)), isTrue);
      expect(asked, 2, reason: 'a real one still does');
    } finally {
      schnorrVerifier = before;
    }
  });

  test('a verifier swapped in later is covered by the next fake signer, and one put back comes back with its check', () {
    final before = schnorrVerifier;
    try {
      final a = FakeSigner('a');
      final digest = sha256Hex([1]);
      final armed = schnorrVerifier;
      // As installNativeSchnorr does: a verifier for real signatures
      // only, in place of the one the check was in front of.
      bool realOnly(PublicKey k, String d, String x) => x.length == 128 && armed(k, d, x);
      schnorrVerifier = realOnly;
      expect(verify(a.publicKey, digest, a.sign(digest)), isFalse, reason: 'the check went with the verifier it was in front of');
      final b = FakeSigner('b');
      expect(verify(a.publicKey, digest, a.sign(digest)), isTrue, reason: 'the next fake signer put one in front of this');
      expect(verify(b.publicKey, digest, b.sign(digest)), isTrue);
      final real = SchnorrSigner.generate();
      expect(verify(real.publicKey, digest, real.sign(digest)), isTrue, reason: 'and real ones go on to the one swapped in');
      schnorrVerifier = armed;
      expect(verify(a.publicKey, digest, a.sign(digest)), isTrue, reason: 'put back, with the check that was over it');
      expect(verify(real.publicKey, digest, real.sign(digest)), isTrue);
    } finally {
      schnorrVerifier = before;
    }
  });

  test('fake keys share a hash, symmetric, that a real key never produces', () {
    final a = FakeSigner('a');
    final b = FakeSigner('b');
    expect(a.sharedSecretWith(b.publicKey), b.sharedSecretWith(a.publicKey));
    expect(a.sharedSecretWith(b.publicKey), isNot(a.sharedSecretWith(FakeSigner('c').publicKey)));
  });
}
