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
}
