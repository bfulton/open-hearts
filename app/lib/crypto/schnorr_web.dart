/// Web: BIP-340 in wasm (web/schnorr.wasm, built from crypto/schnorr_wasm)
/// behind the table package's verifier hook, and a [Signer] that signs
/// through it. Falls back to the Dart implementation if the wasm
/// cannot be fetched, so a table still works, slowly.
library;

import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:table/table.dart';

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
  external JSNumber alloc(JSNumber n);
  external void reset();
  external JSNumber sign(JSNumber sk, JSNumber msg, JSNumber aux, JSNumber out);
  external JSNumber verify(JSNumber pk, JSNumber msg, JSNumber sig);
}

extension type _Memory._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

class _Wasm {
  _Wasm(this.exports) {
    exports.reset();
    sk = exports.alloc(32.toJS).toDartInt;
    msg = exports.alloc(32.toJS).toDartInt;
    aux = exports.alloc(32.toJS).toDartInt;
    sig = exports.alloc(64.toJS).toDartInt;
    pk = exports.alloc(32.toJS).toDartInt;
  }

  final _Exports exports;
  late final int sk, msg, aux, sig, pk;

  Uint8List get _mem => exports.memory.buffer.toDart.asUint8List();

  void _put(int at, String hex) => _mem.setRange(at, at + hex.length ~/ 2, _unhex(hex));

  bool verify(String pubHex, String digestHex, String sigHex) {
    if (pubHex.length != 64 || digestHex.length != 64 || sigHex.length != 128) return false;
    _put(pk, pubHex);
    _put(msg, digestHex);
    _put(sig, sigHex);
    return exports.verify(pk.toJS, msg.toJS, sig.toJS).toDartInt == 1;
  }

  String sign(String secretHex, String digestHex, String auxHex) {
    _put(sk, secretHex);
    _put(msg, digestHex);
    _put(aux, auxHex);
    if (exports.sign(sk.toJS, msg.toJS, aux.toJS, sig.toJS).toDartInt != 1) throw StateError('sign failed');
    final out = _mem.sublist(sig, sig + 64);
    // Leave no secret in linear memory.
    _mem.fillRange(sk, sk + 32, 0);
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

_Wasm? _wasm;

/// Fetches and instantiates the wasm and points the table package's
/// verifier at it. Call once, before any event is parsed.
Future<void> installFastSchnorr() async {
  try {
    final response = await _fetch('schnorr.wasm'.toJS).toDart;
    if (!response.ok) return;
    final bytes = await response.arrayBuffer().toDart;
    final made = await _instantiate(bytes, JSObject()).toDart;
    final w = _Wasm(made.instance.exports);
    // Trust nothing: BIP-340's first vector, before it verifies a thing.
    const pk = 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
    const zero = '0000000000000000000000000000000000000000000000000000000000000000';
    const ref = 'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0';
    if (!w.verify(pk, zero, ref) || w.verify(pk, zero, '${ref.substring(0, 127)}1')) return;
    _wasm = w;
    schnorrVerifier = w.verify;
  } catch (_) {
    // The Dart verifier stays.
  }
}

Signer signerFromSecret(String secretHex) => _wasm == null ? SchnorrSigner.fromSecret(secretHex) : _WasmSigner(secretHex);

class _WasmSigner implements Signer {
  _WasmSigner(this._secretHex) : _dart = SchnorrSigner.fromSecret(_secretHex);

  final String _secretHex;

  /// The Dart signer with the same secret, for what the wasm does not
  /// do: a shared secret is a handful of point multiplications per
  /// hand, not per play, and the Dart curve is fine for that.
  final SchnorrSigner _dart;

  @override
  PublicKey get publicKey => _dart.publicKey;

  @override
  Uint8List sharedSecretWith(PublicKey other) => _dart.sharedSecretWith(other);

  @override
  Uint8List sharedXWith(PublicKey other) => _dart.sharedXWith(other);

  @override
  String sign(String digestHex) {
    final rng = Random.secure();
    final aux = List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return _wasm!.sign(_secretHex, digestHex, aux);
  }
}

Uint8List _unhex(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
