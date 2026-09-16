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
typedef _VerifyToken = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _VerifySeal = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Unmask = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>, Uint8);
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
        _unmask = lib.lookupFunction<_Unmask, int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, int)>('deal_unmask'),
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
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, int) _unmask;
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
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked, {bool verified = false}) {
    final allPks = Uint8List.fromList([for (final p in pks) ...p]);
    final allTokens = Uint8List.fromList([for (final t in tokens) ...t]);
    int? card;
    _call([allPks, allTokens, masked], 0, (i, o) {
      final r = _unmask(i[0], i[1], pks.length, i[2], verified ? 0 : 1);
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
