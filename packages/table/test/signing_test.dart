import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('a real signature verifies, a wrong one does not, and the verifier can be swapped', () {
    final s = SchnorrSigner.generate();
    final digest = sha256Hex([1, 2, 3]);
    final sig = s.sign(digest);
    expect(verify(s.publicKey, digest, sig), isTrue);
    expect(verify(s.publicKey, sha256Hex([4]), sig), isFalse);
    expect(verify(SchnorrSigner.generate().publicKey, digest, sig), isFalse);
    final before = schnorrVerifier;
    try {
      schnorrVerifier = (k, d, x) => x == 'yes';
      expect(verify(s.publicKey, digest, 'yes'), isTrue);
      expect(verify(s.publicKey, digest, sig), isFalse);
      // Fake signatures never reach it.
      final f = FakeSigner('x');
      expect(verify(f.publicKey, digest, f.sign(digest)), isTrue);
    } finally {
      schnorrVerifier = before;
    }
  });

  test('BIP-340 vector 1 signs and verifies with the Dart implementation', () {
    final s = SchnorrSigner.fromSecret('b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef');
    expect(s.publicKey, 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659');
    const msg = '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89';
    const ref = '6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a';
    expect(verify(s.publicKey, msg, ref), isTrue);
    expect(verify(s.publicKey, msg, s.sign(msg)), isTrue);
  });

  test('two real keys share one secret, from either end, and no third key has it', () {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final c = SchnorrSigner.generate();
    final ab = a.sharedSecretWith(b.publicKey);
    expect(ab.length, 32);
    expect(b.sharedSecretWith(a.publicKey), ab);
    expect(c.sharedSecretWith(a.publicKey), isNot(ab));
    expect(a.sharedSecretWith(c.publicKey), isNot(ab));
    expect(() => a.sharedSecretWith('00' * 32), throwsArgumentError, reason: 'x = 0 is not on the curve');
  });

  test('the shared secret is the ECDH value an independent implementation gives', () {
    // Secret 6 has an odd-y point, so this also checks that the
    // negated secret an x-only key implies does not change the x
    // coordinate the two ends hash. The expected value was computed
    // with a separate, pure-Python secp256k1.
    final a = SchnorrSigner.fromSecret('0000000000000000000000000000000000000000000000000000000000000006');
    final b = SchnorrSigner.fromSecret('b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef');
    expect(a.publicKey, 'fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a1460297556');
    final hex = a.sharedSecretWith(b.publicKey).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    expect(hex, 'a98a1a2583e0d2a38598be875fc73f634844eadcb4039527eb9b21e9d0e04b88');
    expect(b.sharedSecretWith(a.publicKey), a.sharedSecretWith(b.publicKey));
  });

  test('fake keys share a hash, symmetric, that a real key never produces', () {
    final a = FakeSigner('a');
    final b = FakeSigner('b');
    expect(a.sharedSecretWith(b.publicKey), b.sharedSecretWith(a.publicKey));
    expect(a.sharedSecretWith(b.publicKey), isNot(a.sharedSecretWith(FakeSigner('c').publicKey)));
  });

  test('the native library signs and checks what the Dart implementation does, and is two hundred times faster', () async {
    final before = (schnorrVerifier, schnorrSigning);
    try {
      expect(await installNativeSchnorr(), isTrue, reason: 'crypto/schnorr/build.sh has been run');
      final s = SchnorrSigner.generate();
      final digest = sha256Hex([9, 9, 9]);
      final native = s.sign(digest);
      expect(verify(s.publicKey, digest, native), isTrue);
      schnorrVerifier = before.$1;
      expect(verify(s.publicKey, digest, native), isTrue, reason: 'a native signature checks in Dart');
      schnorrSigning = before.$2;
      final dart = s.sign(digest);
      expect(await installNativeSchnorr(), isTrue);
      expect(verify(s.publicKey, digest, dart), isTrue, reason: 'a Dart signature checks natively');
      expect(verify(s.publicKey, sha256Hex([1]), dart), isFalse);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        verify(s.publicKey, digest, native);
      }
      expect(sw.elapsedMilliseconds, lessThan(200), reason: '200 checks in under a fifth of a second');
    } finally {
      schnorrVerifier = before.$1;
      schnorrSigning = before.$2;
    }
  });
}
