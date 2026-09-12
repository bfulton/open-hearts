/// The browser's binding: the same Rust as a wasm, instantiated from
/// `deal.wasm` next to the app, driven through its linear memory. No
/// glue library; the module imports nothing.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import '../deal.dart';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('WebAssembly.instantiate')
external JSPromise<_Instantiated> _instantiate(JSArrayBuffer bytes, JSObject imports);

extension type _Instantiated._(JSObject _) implements JSObject {
  external _Instance get instance;
}

extension type _Instance._(JSObject _) implements JSObject {
  external _Exports get exports;
}

extension type _Exports._(JSObject _) implements JSObject {
  external _Memory get memory;
  // ignore: non_constant_identifier_names
  external void deal_setup();
  // ignore: non_constant_identifier_names
  external JSNumber deal_alloc(JSNumber n);
  // ignore: non_constant_identifier_names
  external void deal_free(JSNumber p, JSNumber n);
  // ignore: non_constant_identifier_names
  external JSNumber deal_keygen(JSNumber secret, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_key_proof(JSNumber secret, JSNumber name, JSNumber nameLen, JSNumber seed, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_verify_key(JSNumber pk, JSNumber name, JSNumber nameLen, JSNumber proof);
  // ignore: non_constant_identifier_names
  external JSNumber deal_aggregate(JSNumber pks, JSNumber count, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_initial_deck(JSNumber joint, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_shuffle(JSNumber joint, JSNumber deckIn, JSNumber seed, JSNumber deckOut, JSNumber proofOut, JSNumber proofCap);
  // ignore: non_constant_identifier_names
  external JSNumber deal_verify_shuffle(JSNumber joint, JSNumber deckIn, JSNumber deckOut, JSNumber proof, JSNumber proofLen);
  // ignore: non_constant_identifier_names
  external JSNumber deal_reveal_token(JSNumber secret, JSNumber masked, JSNumber seed, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_verify_token(JSNumber pk, JSNumber masked, JSNumber token);
  // ignore: non_constant_identifier_names
  external JSNumber deal_unmask(JSNumber pks, JSNumber tokens, JSNumber count, JSNumber masked, JSNumber check);
  // ignore: non_constant_identifier_names
  external JSNumber deal_seal(JSNumber pk, JSNumber token, JSNumber seed, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_open(JSNumber secret, JSNumber sealed, JSNumber out);
  // ignore: non_constant_identifier_names
  external JSNumber deal_shared_secret(JSNumber secret, JSNumber pk, JSNumber out);
}

extension type _Memory._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

/// Fetches `deal.wasm` from where the app is served and instantiates
/// it. [libraryPath] names a different URL.
Future<DealCrypto> load({String? libraryPath}) async {
  final response = await _fetch((libraryPath ?? 'deal.wasm').toJS).toDart;
  if (!response.ok) throw StateError('deal.wasm is not served');
  final bytes = await response.arrayBuffer().toDart;
  final made = await _instantiate(bytes, JSObject()).toDart;
  final e = made.instance.exports;
  e.deal_setup();
  return _Wasm(e);
}

class _Wasm implements DealCrypto {
  _Wasm(this.e);

  final _Exports e;

  // The memory's buffer is replaced when the module grows it, so it is
  // read afresh at every use, never kept.
  Uint8List get _mem => e.memory.buffer.toDart.asUint8List();

  int _alloc(int n) => e.deal_alloc(n.toJS).toDartInt;
  void _free(int p, int n) => e.deal_free(p.toJS, n.toJS);

  /// Copies the inputs in, gives [f] their addresses and an output of
  /// [outLen], and returns what was written; null on a negative result.
  Uint8List? _call(List<Uint8List> ins, int outLen, int Function(List<int> ins, int out) f) {
    final ptrs = <(int, int)>[];
    final out = _alloc(outLen == 0 ? 1 : outLen);
    try {
      for (final b in ins) {
        final n = b.isEmpty ? 1 : b.length;
        final p = _alloc(n);
        _mem.setRange(p, p + b.length, b);
        ptrs.add((p, n));
      }
      final n = f([for (final p in ptrs) p.$1], out);
      if (n < 0) return null;
      return Uint8List.fromList(_mem.sublist(out, out + n));
    } finally {
      for (final (p, n) in ptrs) {
        _free(p, n);
      }
      _free(out, outLen == 0 ? 1 : outLen);
    }
  }

  Uint8List _must(Uint8List? r, String what) => r ?? (throw StateError('$what failed'));

  @override
  Uint8List keygen(Uint8List secret) => _must(_call([secret], pointBytes, (i, o) => e.deal_keygen(i[0].toJS, o.toJS).toDartInt), 'keygen');

  @override
  Uint8List keyProof(Uint8List secret, Uint8List name, Uint8List seed) => _must(
      _call([secret, name, seed], keyProofBytes, (i, o) => e.deal_key_proof(i[0].toJS, i[1].toJS, name.length.toJS, i[2].toJS, o.toJS).toDartInt),
      'key proof');

  @override
  bool verifyKey(Uint8List pk, Uint8List name, Uint8List proof) =>
      _call([pk, name, proof], 0, (i, o) => e.deal_verify_key(i[0].toJS, i[1].toJS, name.length.toJS, i[2].toJS).toDartInt == 1 ? 0 : -1) != null;

  @override
  Uint8List aggregate(List<Uint8List> pks) {
    final all = Uint8List.fromList([for (final p in pks) ...p]);
    return _must(_call([all], pointBytes, (i, o) => e.deal_aggregate(i[0].toJS, pks.length.toJS, o.toJS).toDartInt), 'aggregate');
  }

  @override
  Uint8List initialDeck(Uint8List joint) => _must(_call([joint], deckBytes, (i, o) => e.deal_initial_deck(i[0].toJS, o.toJS).toDartInt), 'initial deck');

  @override
  ({Uint8List deck, Uint8List proof}) shuffle(Uint8List joint, Uint8List deck, Uint8List seed) {
    const proofCap = 16384;
    final deckOut = _alloc(deckBytes);
    try {
      final proof = _must(
          _call([joint, deck, seed], proofCap, (i, o) => e.deal_shuffle(i[0].toJS, i[1].toJS, i[2].toJS, deckOut.toJS, o.toJS, proofCap.toJS).toDartInt),
          'shuffle');
      return (deck: Uint8List.fromList(_mem.sublist(deckOut, deckOut + deckBytes)), proof: proof);
    } finally {
      _free(deckOut, deckBytes);
    }
  }

  @override
  bool verifyShuffle(Uint8List joint, Uint8List before, Uint8List after, Uint8List proof) => _call(
          [joint, before, after, proof], 0, (i, o) => e.deal_verify_shuffle(i[0].toJS, i[1].toJS, i[2].toJS, i[3].toJS, proof.length.toJS).toDartInt == 1 ? 0 : -1) !=
      null;

  @override
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed) =>
      _must(_call([secret, masked, seed], tokenBytes, (i, o) => e.deal_reveal_token(i[0].toJS, i[1].toJS, i[2].toJS, o.toJS).toDartInt), 'reveal token');

  @override
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token) =>
      _call([pk, masked, token], 0, (i, o) => e.deal_verify_token(i[0].toJS, i[1].toJS, i[2].toJS).toDartInt == 1 ? 0 : -1) != null;

  @override
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked, {bool verified = false}) {
    final allPks = Uint8List.fromList([for (final p in pks) ...p]);
    final allTokens = Uint8List.fromList([for (final t in tokens) ...t]);
    int? card;
    _call([allPks, allTokens, masked], 0, (i, o) {
      final r = e.deal_unmask(i[0].toJS, i[1].toJS, pks.length.toJS, i[2].toJS, (verified ? 0 : 1).toJS).toDartInt;
      card = r < 0 ? null : r;
      return 0;
    });
    return card;
  }

  @override
  Uint8List seal(Uint8List pk, Uint8List token, Uint8List seed) =>
      _must(_call([pk, token, seed], sealedBytes, (i, o) => e.deal_seal(i[0].toJS, i[1].toJS, i[2].toJS, o.toJS).toDartInt), 'seal');

  @override
  Uint8List open(Uint8List secret, Uint8List sealed) =>
      _must(_call([secret, sealed], pointBytes, (i, o) => e.deal_open(i[0].toJS, i[1].toJS, o.toJS).toDartInt), 'open');

  @override
  Uint8List sharedSecret(Uint8List secret, Uint8List pk) =>
      _must(_call([secret, pk], 32, (i, o) => e.deal_shared_secret(i[0].toJS, i[1].toJS, o.toJS).toDartInt), 'shared secret');
}
