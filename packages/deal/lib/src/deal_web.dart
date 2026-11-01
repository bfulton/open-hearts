/// The browser's binding: the same Rust as a wasm, instantiated from
/// `deal.wasm` next to the app, driven through its linear memory. No
/// glue library; the module imports nothing.
library;

// The wasm's exports keep the names the Rust gives them (deal_setup and
// the rest): they are the properties' names on the JavaScript side.
// ignore_for_file: non_constant_identifier_names

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
  external void deal_setup();
  external JSNumber deal_alloc(JSNumber n);
  external void deal_free(JSNumber p, JSNumber n);
  external JSNumber deal_keygen(JSNumber secret, JSNumber out);
  external JSNumber deal_key_proof(JSNumber secret, JSNumber name, JSNumber nameLen, JSNumber seed, JSNumber out);
  external JSNumber deal_verify_key(JSNumber pk, JSNumber name, JSNumber nameLen, JSNumber proof);
  external JSNumber deal_aggregate(JSNumber pks, JSNumber count, JSNumber out);
  external JSNumber deal_initial_deck(JSNumber joint, JSNumber out);
  external JSNumber deal_shuffle(JSNumber joint, JSNumber deckIn, JSNumber seed, JSNumber deckOut, JSNumber proofOut, JSNumber proofCap);
  external JSNumber deal_verify_shuffle(JSNumber joint, JSNumber deckIn, JSNumber deckOut, JSNumber proof, JSNumber proofLen);
  external JSNumber deal_reveal_token(JSNumber secret, JSNumber masked, JSNumber seed, JSNumber out);
  external JSNumber deal_verify_token(JSNumber pk, JSNumber masked, JSNumber token);
  external JSNumber deal_split(JSNumber secret, JSNumber shares, JSNumber seed, JSNumber out);
  external JSNumber deal_share_key(JSNumber share, JSNumber out);
  external JSNumber deal_share_bytes(JSNumber secret, JSNumber len, JSNumber n, JSNumber t, JSNumber seed, JSNumber out);
  external JSNumber deal_bytes_lagrange(JSNumber have, JSNumber count, JSNumber index, JSNumber at);
  external JSNumber deal_bytes_scale(JSNumber share, JSNumber len, JSNumber by, JSNumber out);
  external JSNumber deal_bytes_sum(JSNumber parts, JSNumber count, JSNumber len, JSNumber out);
  external JSNumber deal_split_threshold(JSNumber secret, JSNumber n, JSNumber t, JSNumber seed, JSNumber out);
  external JSNumber deal_lagrange(JSNumber have, JSNumber count, JSNumber index, JSNumber at, JSNumber out);
  external JSNumber deal_scalar_mul(JSNumber a, JSNumber b, JSNumber out);
  external JSNumber deal_scalar_sum(JSNumber parts, JSNumber count, JSNumber out);
  external JSNumber deal_point_scale(JSNumber point, JSNumber scalar, JSNumber out);
  external JSNumber deal_open_shared(JSNumber sealed, JSNumber parts, JSNumber count, JSNumber out);
  external JSNumber deal_share_token(JSNumber share, JSNumber masked, JSNumber seed, JSNumber out);
  external JSNumber deal_unmask(JSNumber pks, JSNumber tokens, JSNumber count, JSNumber masked);
  external JSNumber deal_reveal_tokens(JSNumber secret, JSNumber masked, JSNumber count, JSNumber seed, JSNumber out);
  external JSNumber deal_verify_tokens(JSNumber pk, JSNumber masked, JSNumber count, JSNumber tokens);
  external JSNumber deal_seal(JSNumber secret, JSNumber pkTo, JSNumber masked, JSNumber seed, JSNumber out);
  external JSNumber deal_verify_seal(JSNumber pkOwner, JSNumber pkTo, JSNumber masked, JSNumber sealed);
  external JSNumber deal_open(JSNumber secret, JSNumber sealed, JSNumber out);
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
  ///
  /// [sizes] gives, input by input, how many bytes the Rust reads from
  /// it, or null for an input whose length is passed beside it. The
  /// Rust reads that many whatever it was given, which in linear memory
  /// is whatever lies after the input, so an input of any other length
  /// is refused here, as null, and [f] is never called.
  Uint8List? _call(List<Uint8List> ins, List<int?> sizes, int outLen, int Function(List<int> ins, int out) f) {
    for (var k = 0; k < ins.length; k++) {
      if (sizes[k] != null && ins[k].length != sizes[k]) return null;
    }
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

  /// Pieces of one size end to end, as the Rust takes a list of them;
  /// null when any is not that size.
  Uint8List? _joined(List<Uint8List> pieces, int size) =>
      pieces.every((p) => p.length == size) ? Uint8List.fromList([for (final p in pieces) ...p]) : null;

  @override
  Uint8List keygen(Uint8List secret) =>
      _must(_call([secret], [scalarBytes], pointBytes, (i, o) => e.deal_keygen(i[0].toJS, o.toJS).toDartInt), 'keygen');

  @override
  Uint8List keyProof(Uint8List secret, Uint8List name, Uint8List seed) => _must(
      _call([secret, name, seed], [scalarBytes, null, seedBytes], keyProofBytes,
          (i, o) => e.deal_key_proof(i[0].toJS, i[1].toJS, name.length.toJS, i[2].toJS, o.toJS).toDartInt),
      'key proof');

  @override
  bool verifyKey(Uint8List pk, Uint8List name, Uint8List proof) =>
      _call([pk, name, proof], [pointBytes, null, keyProofBytes], 0,
          (i, o) => e.deal_verify_key(i[0].toJS, i[1].toJS, name.length.toJS, i[2].toJS).toDartInt == 1 ? 0 : -1) !=
      null;

  @override
  Uint8List aggregate(List<Uint8List> pks) {
    final all = _must(_joined(pks, pointBytes), 'aggregate');
    return _must(_call([all], [null], pointBytes, (i, o) => e.deal_aggregate(i[0].toJS, pks.length.toJS, o.toJS).toDartInt), 'aggregate');
  }

  @override
  Uint8List initialDeck(Uint8List joint) =>
      _must(_call([joint], [pointBytes], deckBytes, (i, o) => e.deal_initial_deck(i[0].toJS, o.toJS).toDartInt), 'initial deck');

  @override
  ({Uint8List deck, Uint8List proof}) shuffle(Uint8List joint, Uint8List deck, Uint8List seed) {
    const proofCap = 16384;
    final deckOut = _alloc(deckBytes);
    try {
      final proof = _must(
          _call([joint, deck, seed], [pointBytes, deckBytes, seedBytes], proofCap,
              (i, o) => e.deal_shuffle(i[0].toJS, i[1].toJS, i[2].toJS, deckOut.toJS, o.toJS, proofCap.toJS).toDartInt),
          'shuffle');
      return (deck: Uint8List.fromList(_mem.sublist(deckOut, deckOut + deckBytes)), proof: proof);
    } finally {
      _free(deckOut, deckBytes);
    }
  }

  @override
  bool verifyShuffle(Uint8List joint, Uint8List before, Uint8List after, Uint8List proof) =>
      _call([joint, before, after, proof], [pointBytes, deckBytes, deckBytes, null], 0,
          (i, o) => e.deal_verify_shuffle(i[0].toJS, i[1].toJS, i[2].toJS, i[3].toJS, proof.length.toJS).toDartInt == 1 ? 0 : -1) !=
      null;

  @override
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed) => _must(
      _call([secret, masked, seed], [scalarBytes, maskedBytes, seedBytes], tokenBytes,
          (i, o) => e.deal_reveal_token(i[0].toJS, i[1].toJS, i[2].toJS, o.toJS).toDartInt),
      'reveal token');

  @override
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token) =>
      _call([pk, masked, token], [pointBytes, maskedBytes, tokenBytes], 0,
          (i, o) => e.deal_verify_token(i[0].toJS, i[1].toJS, i[2].toJS).toDartInt == 1 ? 0 : -1) !=
      null;

  @override
  Uint8List split(Uint8List secret, Uint8List seed, {int shares = 2}) => _must(
      _call([secret, seed], [scalarBytes, seedBytes], shares * scalarBytes,
          (i, o) => e.deal_split(i[0].toJS, shares.toJS, i[1].toJS, o.toJS).toDartInt),
      'split');

  @override
  Uint8List openShared(Uint8List sealed, List<Uint8List> parts) {
    final all = Uint8List.fromList([for (final p in parts) ...Uint8List.sublistView(p, 0, pointBytes)]);
    return _must(
        _call([sealed, all], [sealedBytes, null], pointBytes,
            (i, o) => e.deal_open_shared(i[0].toJS, i[1].toJS, parts.length.toJS, o.toJS).toDartInt),
        'open shared');
  }

  @override
  Uint8List shareBytes(Uint8List secret, {required int n, required int t, required Uint8List seed}) => _must(
      _call([secret, seed], [null, seedBytes], n * secret.length,
          (i, o) => e.deal_share_bytes(i[0].toJS, secret.length.toJS, n.toJS, t.toJS, i[1].toJS, o.toJS).toDartInt),
      'share bytes');

  @override
  int bytesLagrange(List<int> have, int index, {int at = 0}) {
    var c = -1;
    _call([Uint8List.fromList(have)], [null], 0, (i, o) {
      c = e.deal_bytes_lagrange(i[0].toJS, have.length.toJS, index.toJS, at.toJS).toDartInt;
      return 0;
    });
    if (c < 0) throw StateError('bytes lagrange');
    return c;
  }

  @override
  Uint8List bytesScale(Uint8List share, int by) => _must(
      _call([share], [null], share.length, (i, o) => e.deal_bytes_scale(i[0].toJS, share.length.toJS, by.toJS, o.toJS).toDartInt),
      'bytes scale');

  @override
  Uint8List bytesSum(List<Uint8List> parts) {
    final len = parts.first.length;
    final all = _must(_joined(parts, len), 'bytes sum');
    return _must(
        _call([all], [null], len, (i, o) => e.deal_bytes_sum(i[0].toJS, parts.length.toJS, len.toJS, o.toJS).toDartInt), 'bytes sum');
  }

  @override
  Uint8List splitThreshold(Uint8List secret, {required int n, required int t, required Uint8List seed}) => _must(
      _call([secret, seed], [scalarBytes, seedBytes], n * scalarBytes,
          (i, o) => e.deal_split_threshold(i[0].toJS, n.toJS, t.toJS, i[1].toJS, o.toJS).toDartInt),
      'split threshold');

  @override
  Uint8List lagrange(List<int> have, int index, {int at = 0}) => _must(
      _call([Uint8List.fromList(have)], [null], scalarBytes,
          (i, o) => e.deal_lagrange(i[0].toJS, have.length.toJS, index.toJS, at.toJS, o.toJS).toDartInt),
      'lagrange');

  @override
  Uint8List scalarMul(Uint8List a, Uint8List b) => _must(
      _call([a, b], [scalarBytes, scalarBytes], scalarBytes, (i, o) => e.deal_scalar_mul(i[0].toJS, i[1].toJS, o.toJS).toDartInt),
      'scalar mul');

  @override
  Uint8List scalarSum(List<Uint8List> parts) {
    final all = _must(_joined(parts, scalarBytes), 'scalar sum');
    return _must(
        _call([all], [null], scalarBytes, (i, o) => e.deal_scalar_sum(i[0].toJS, parts.length.toJS, o.toJS).toDartInt), 'scalar sum');
  }

  @override
  Uint8List pointScale(Uint8List point, Uint8List scalar) => _must(
      _call([point, scalar], [pointBytes, scalarBytes], pointBytes, (i, o) => e.deal_point_scale(i[0].toJS, i[1].toJS, o.toJS).toDartInt),
      'point scale');

  @override
  Uint8List shareKey(Uint8List share) =>
      _must(_call([share], [scalarBytes], pointBytes, (i, o) => e.deal_share_key(i[0].toJS, o.toJS).toDartInt), 'share key');

  @override
  Uint8List shareToken(Uint8List share, Uint8List masked, Uint8List seed) => _must(
      _call([share, masked, seed], [scalarBytes, maskedBytes, seedBytes], tokenBytes,
          (i, o) => e.deal_share_token(i[0].toJS, i[1].toJS, i[2].toJS, o.toJS).toDartInt),
      'share token');

  @override
  Uint8List revealTokens(Uint8List secret, Uint8List cards, Uint8List seed) {
    final n = cards.length ~/ maskedBytes;
    return _must(
        _call([secret, cards, seed], [scalarBytes, n * maskedBytes, seedBytes], tokensBytes(n),
            (i, o) => e.deal_reveal_tokens(i[0].toJS, i[1].toJS, n.toJS, i[2].toJS, o.toJS).toDartInt),
        'reveal tokens');
  }

  @override
  bool verifyTokens(Uint8List pk, Uint8List cards, Uint8List tokens) {
    final n = cards.length ~/ maskedBytes;
    return _call([pk, cards, tokens], [pointBytes, n * maskedBytes, tokensBytes(n)], 0,
            (i, o) => e.deal_verify_tokens(i[0].toJS, i[1].toJS, n.toJS, i[2].toJS).toDartInt == 1 ? 0 : -1) !=
        null;
  }

  @override
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked) {
    final allPks = _joined(pks, pointBytes);
    final allTokens = _joined(tokens, pointBytes);
    if (allPks == null || allTokens == null || tokens.length != pks.length) return null;
    int? card;
    _call([allPks, allTokens, masked], [null, null, maskedBytes], 0, (i, o) {
      final r = e.deal_unmask(i[0].toJS, i[1].toJS, pks.length.toJS, i[2].toJS).toDartInt;
      card = r < 0 ? null : r;
      return 0;
    });
    return card;
  }

  @override
  Uint8List seal(Uint8List secret, Uint8List pkTo, Uint8List masked, Uint8List seed) => _must(
      _call([secret, pkTo, masked, seed], [scalarBytes, pointBytes, maskedBytes, seedBytes], sealedBytes + sealProofBytes,
          (i, o) => e.deal_seal(i[0].toJS, i[1].toJS, i[2].toJS, i[3].toJS, o.toJS).toDartInt),
      'seal');

  @override
  bool verifySeal(Uint8List pkOwner, Uint8List pkTo, Uint8List masked, Uint8List sealed) =>
      _call([pkOwner, pkTo, masked, sealed], [pointBytes, pointBytes, maskedBytes, sealedBytes + sealProofBytes], 0,
          (i, o) => e.deal_verify_seal(i[0].toJS, i[1].toJS, i[2].toJS, i[3].toJS).toDartInt == 1 ? 0 : -1) !=
      null;

  @override
  Uint8List open(Uint8List secret, Uint8List sealed) => _must(
      _call([secret, sealed], [scalarBytes, sealedBytes], pointBytes, (i, o) => e.deal_open(i[0].toJS, i[1].toJS, o.toJS).toDartInt),
      'open');

  @override
  Uint8List sharedSecret(Uint8List secret, Uint8List pk) => _must(
      _call([secret, pk], [scalarBytes, pointBytes], 32, (i, o) => e.deal_shared_secret(i[0].toJS, i[1].toJS, o.toJS).toDartInt),
      'shared secret');
}
