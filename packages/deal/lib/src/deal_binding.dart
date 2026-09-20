/// The VM's binding: the cdylib over dart:ffi.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../deal.dart';

typedef _Keygen = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _KeyProof = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>, Pointer<Uint8>);
typedef _VerifyKey = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _Aggregate = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _InitialDeck = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _Shuffle = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Size);
typedef _VerifyShuffle = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Size);
typedef _RevealToken = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Split = Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, Pointer<Uint8>);
typedef _ShareKey = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _OpenShared = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, IntPtr, Pointer<Uint8>);
typedef _VerifyToken = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _VerifySeal = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Unmask = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _SplitThreshold = Int32 Function(Pointer<Uint8>, Size, Size, Pointer<Uint8>, Pointer<Uint8>);
typedef _Lagrange = Int32 Function(Pointer<Uint8>, Size, Uint8, Uint8, Pointer<Uint8>);
typedef _TwoScalars = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _ScalarSum = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _RevealTokens = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>, Pointer<Uint8>);
typedef _VerifyTokens = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _Seal = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Open = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Shared = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

/// Where the cdylib is: [libraryPath], else the crate's release build
/// next to this package.
Future<DealCrypto> load({String? libraryPath}) async {
  final path = libraryPath ?? _defaultPath();
  return _Ffi(DynamicLibrary.open(path));
}

String _defaultPath() {
  final here = File.fromUri(Platform.script).parent.path;
  // From a test in packages/deal, or the package root, or the repo root.
  for (final base in [Directory.current.path, here, '${Directory.current.path}/..', '${Directory.current.path}/../..']) {
    for (final name in ['libdeal.so', 'libdeal.dylib', 'deal.dll']) {
      final p = '$base/crypto/deal/target/release/$name';
      if (File(p).existsSync()) return p;
      final q = '$base/../crypto/deal/target/release/$name';
      if (File(q).existsSync()) return q;
    }
  }
  throw StateError('the deal cdylib is not built: run crypto/deal/build.sh');
}

class _Ffi implements DealCrypto {
  _Ffi(DynamicLibrary lib)
      : _keygen = lib.lookupFunction<_Keygen, int Function(Pointer<Uint8>, Pointer<Uint8>)>('deal_keygen'),
        _keyProof = lib.lookupFunction<_KeyProof, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>)>('deal_key_proof'),
        _verifyKey = lib.lookupFunction<_VerifyKey, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)>('deal_verify_key'),
        _aggregate = lib.lookupFunction<_Aggregate, int Function(Pointer<Uint8>, int, Pointer<Uint8>)>('deal_aggregate'),
        _initialDeck = lib.lookupFunction<_InitialDeck, int Function(Pointer<Uint8>, Pointer<Uint8>)>('deal_initial_deck'),
        _shuffle = lib.lookupFunction<_Shuffle, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)>('deal_shuffle'),
        _verifyShuffle = lib.lookupFunction<_VerifyShuffle, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)>('deal_verify_shuffle'),
        _revealToken = lib.lookupFunction<_RevealToken, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_reveal_token'),
        _verifyToken = lib.lookupFunction<_VerifyToken, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_verify_token'),
        _split = lib.lookupFunction<_Split, int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>)>('deal_split'),
        _shareKey = lib.lookupFunction<_ShareKey, int Function(Pointer<Uint8>, Pointer<Uint8>)>('deal_share_key'),
        _openShared = lib.lookupFunction<_OpenShared, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)>('deal_open_shared'),
        _shareToken = lib.lookupFunction<_RevealToken, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_share_token'),
        _unmask = lib.lookupFunction<_Unmask, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)>('deal_unmask'),
        _splitThreshold =
            lib.lookupFunction<_SplitThreshold, int Function(Pointer<Uint8>, int, int, Pointer<Uint8>, Pointer<Uint8>)>('deal_split_threshold'),
        _lagrange = lib.lookupFunction<_Lagrange, int Function(Pointer<Uint8>, int, int, int, Pointer<Uint8>)>('deal_lagrange'),
        _scalarMul = lib.lookupFunction<_TwoScalars, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_scalar_mul'),
        _scalarSum = lib.lookupFunction<_ScalarSum, int Function(Pointer<Uint8>, int, Pointer<Uint8>)>('deal_scalar_sum'),
        _pointScale = lib.lookupFunction<_TwoScalars, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_point_scale'),
        _revealTokens =
            lib.lookupFunction<_RevealTokens, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>)>('deal_reveal_tokens'),
        _verifyTokens = lib.lookupFunction<_VerifyTokens, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)>('deal_verify_tokens'),
        _seal = lib.lookupFunction<_Seal, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_seal'),
        _verifySeal =
            lib.lookupFunction<_VerifySeal, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_verify_seal'),
        _open = lib.lookupFunction<_Open, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_open'),
        _shared = lib.lookupFunction<_Shared, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('deal_shared_secret') {
    lib.lookupFunction<Void Function(), void Function()>('deal_setup')();
  }

  final int Function(Pointer<Uint8>, Pointer<Uint8>) _keygen;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>) _keyProof;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>) _verifyKey;
  final int Function(Pointer<Uint8>, int, Pointer<Uint8>) _aggregate;
  final int Function(Pointer<Uint8>, Pointer<Uint8>) _initialDeck;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int) _shuffle;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int) _verifyShuffle;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _revealToken;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _verifyToken;
  final int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>) _split;
  final int Function(Pointer<Uint8>, Pointer<Uint8>) _shareKey;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>) _openShared;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _shareToken;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>) _unmask;
  final int Function(Pointer<Uint8>, int, int, Pointer<Uint8>, Pointer<Uint8>) _splitThreshold;
  final int Function(Pointer<Uint8>, int, int, int, Pointer<Uint8>) _lagrange;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _scalarMul;
  final int Function(Pointer<Uint8>, int, Pointer<Uint8>) _scalarSum;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _pointScale;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>) _revealTokens;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>) _verifyTokens;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _seal;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _verifySeal;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _open;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _shared;

  /// Runs [f] with the inputs copied into native memory and an output
  /// buffer of [outLen], and returns the bytes written (a negative
  /// result is an error).
  Uint8List? _call(List<Uint8List> ins, int outLen, int Function(List<Pointer<Uint8>> ins, Pointer<Uint8> out) f) {
    final ptrs = <Pointer<Uint8>>[];
    final out = malloc<Uint8>(outLen == 0 ? 1 : outLen);
    try {
      for (final b in ins) {
        final p = malloc<Uint8>(b.isEmpty ? 1 : b.length);
        p.asTypedList(b.isEmpty ? 1 : b.length).setAll(0, b);
        ptrs.add(p);
      }
      final n = f(ptrs, out);
      if (n < 0) return null;
      return Uint8List.fromList(out.asTypedList(n));
    } finally {
      for (final p in ptrs) {
        malloc.free(p);
      }
      malloc.free(out);
    }
  }

  Uint8List _must(Uint8List? r, String what) => r ?? (throw StateError('$what failed'));

  @override
  Uint8List keygen(Uint8List secret) => _must(_call([secret], pointBytes, (i, o) => _keygen(i[0], o)), 'keygen');

  @override
  Uint8List keyProof(Uint8List secret, Uint8List name, Uint8List seed) =>
      _must(_call([secret, name, seed], keyProofBytes, (i, o) => _keyProof(i[0], i[1], name.length, i[2], o)), 'key proof');

  @override
  bool verifyKey(Uint8List pk, Uint8List name, Uint8List proof) =>
      _call([pk, name, proof], 0, (i, o) => _verifyKey(i[0], i[1], name.length, i[2]) == 1 ? 0 : -1) != null;

  @override
  Uint8List aggregate(List<Uint8List> pks) {
    final all = Uint8List.fromList([for (final p in pks) ...p]);
    return _must(_call([all], pointBytes, (i, o) => _aggregate(i[0], pks.length, o)), 'aggregate');
  }

  @override
  Uint8List initialDeck(Uint8List joint) => _must(_call([joint], deckBytes, (i, o) => _initialDeck(i[0], o)), 'initial deck');

  @override
  ({Uint8List deck, Uint8List proof}) shuffle(Uint8List joint, Uint8List deck, Uint8List seed) {
    const proofCap = 16384;
    final deckOut = malloc<Uint8>(deckBytes);
    try {
      final proof = _must(_call([joint, deck, seed], proofCap, (i, o) => _shuffle(i[0], i[1], i[2], deckOut, o, proofCap)), 'shuffle');
      return (deck: Uint8List.fromList(deckOut.asTypedList(deckBytes)), proof: proof);
    } finally {
      malloc.free(deckOut);
    }
  }

  @override
  bool verifyShuffle(Uint8List joint, Uint8List before, Uint8List after, Uint8List proof) =>
      _call([joint, before, after, proof], 0, (i, o) => _verifyShuffle(i[0], i[1], i[2], i[3], proof.length) == 1 ? 0 : -1) != null;

  @override
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed) =>
      _must(_call([secret, masked, seed], tokenBytes, (i, o) => _revealToken(i[0], i[1], i[2], o)), 'reveal token');

  @override
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token) =>
      _call([pk, masked, token], 0, (i, o) => _verifyToken(i[0], i[1], i[2]) == 1 ? 0 : -1) != null;

  @override
  Uint8List split(Uint8List secret, Uint8List seed, {int shares = 2}) =>
      _must(_call([secret, seed], shares * scalarBytes, (i, o) => _split(i[0], shares, i[1], o)), 'split');

  @override
  Uint8List openShared(Uint8List sealed, List<Uint8List> parts) {
    final all = Uint8List.fromList([for (final p in parts) ...Uint8List.sublistView(p, 0, pointBytes)]);
    return _must(_call([sealed, all], pointBytes, (i, o) => _openShared(i[0], i[1], parts.length, o)), 'open shared');
  }

  @override
  Uint8List splitThreshold(Uint8List secret, {required int n, required int t, required Uint8List seed}) =>
      _must(_call([secret, seed], n * scalarBytes, (i, o) => _splitThreshold(i[0], n, t, i[1], o)), 'split threshold');

  @override
  Uint8List lagrange(List<int> have, int index, {int at = 0}) => _must(
      _call([Uint8List.fromList(have)], scalarBytes, (i, o) => _lagrange(i[0], have.length, index, at, o)), 'lagrange');

  @override
  Uint8List scalarMul(Uint8List a, Uint8List b) => _must(_call([a, b], scalarBytes, (i, o) => _scalarMul(i[0], i[1], o)), 'scalar mul');

  @override
  Uint8List scalarSum(List<Uint8List> parts) => _must(
      _call([Uint8List.fromList([for (final p in parts) ...p])], scalarBytes, (i, o) => _scalarSum(i[0], parts.length, o)), 'scalar sum');

  @override
  Uint8List pointScale(Uint8List point, Uint8List scalar) =>
      _must(_call([point, scalar], pointBytes, (i, o) => _pointScale(i[0], i[1], o)), 'point scale');

  @override
  Uint8List shareKey(Uint8List share) => _must(_call([share], pointBytes, (i, o) => _shareKey(i[0], o)), 'share key');

  @override
  Uint8List shareToken(Uint8List share, Uint8List masked, Uint8List seed) =>
      _must(_call([share, masked, seed], tokenBytes, (i, o) => _shareToken(i[0], i[1], i[2], o)), 'share token');

  @override
  Uint8List revealTokens(Uint8List secret, Uint8List cards, Uint8List seed) {
    final n = cards.length ~/ maskedBytes;
    return _must(_call([secret, cards, seed], tokensBytes(n), (i, o) => _revealTokens(i[0], i[1], n, i[2], o)), 'reveal tokens');
  }

  @override
  bool verifyTokens(Uint8List pk, Uint8List cards, Uint8List tokens) {
    final n = cards.length ~/ maskedBytes;
    return _call([pk, cards, tokens], 0, (i, o) => _verifyTokens(i[0], i[1], n, i[2]) == 1 ? 0 : -1) != null;
  }

  @override
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked) {
    final allPks = Uint8List.fromList([for (final p in pks) ...p]);
    final allTokens = Uint8List.fromList([for (final t in tokens) ...t]);
    int? card;
    _call([allPks, allTokens, masked], 0, (i, o) {
      final r = _unmask(i[0], i[1], pks.length, i[2]);
      card = r < 0 ? null : r;
      return 0;
    });
    return card;
  }

  @override
  Uint8List seal(Uint8List secret, Uint8List pkTo, Uint8List masked, Uint8List seed) => _must(
      _call([secret, pkTo, masked, seed], sealedBytes + sealProofBytes, (i, o) => _seal(i[0], i[1], i[2], i[3], o)), 'seal');

  @override
  bool verifySeal(Uint8List pkOwner, Uint8List pkTo, Uint8List masked, Uint8List sealed) =>
      _call([pkOwner, pkTo, masked, sealed], 0, (i, o) => _verifySeal(i[0], i[1], i[2], i[3]) == 1 ? 0 : -1) != null;

  @override
  Uint8List open(Uint8List secret, Uint8List sealed) => _must(_call([secret, sealed], pointBytes, (i, o) => _open(i[0], i[1], o)), 'open');

  @override
  Uint8List sharedSecret(Uint8List secret, Uint8List pk) => _must(_call([secret, pk], 32, (i, o) => _shared(i[0], i[1], o)), 'shared secret');
}
