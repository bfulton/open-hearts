/// The cdylib over FFI, checked against a BIP-340 vector before it is
/// trusted with anything.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'signing.dart';

typedef _SignC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _VerifyC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

/// Loads the cdylib — [libraryPath], else the crate's release build
/// found from the working directory — and swaps it in for signing and
/// verifying. False, and the pure-Dart implementation stays, when
/// there is none to load.
Future<bool> installNativeSchnorr({String? libraryPath}) async {
  final path = libraryPath ?? _find();
  if (path == null) return false;
  try {
    final lib = DynamicLibrary.open(path);
    final sign = lib.lookupFunction<_SignC, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('schnorr_sign');
    final verify = lib.lookupFunction<_VerifyC, int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>('schnorr_verify');
    final native = _Native(sign, verify);
    // BIP-340 vector 0: refuse a library that gets it wrong.
    const pk = 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
    const zero = '0000000000000000000000000000000000000000000000000000000000000000';
    const ref = 'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0';
    if (!native.verify(pk, zero, ref) || native.verify(pk, zero, '${ref.substring(0, 127)}1')) return false;
    if (native.sign('${zero.substring(0, 63)}3', zero, zero) != ref) return false;
    schnorrVerifier = native.verify;
    schnorrSigning = native.sign;
    return true;
  } catch (_) {
    return false;
  }
}

String? _find() {
  final here = File.fromUri(Platform.script).parent.path;
  for (final base in [Directory.current.path, here, '${Directory.current.path}/..', '${Directory.current.path}/../..']) {
    for (final name in ['libschnorr.so', 'libschnorr.dylib', 'schnorr.dll']) {
      for (final p in ['$base/crypto/schnorr/target/release/$name', '$base/../crypto/schnorr/target/release/$name']) {
        if (File(p).existsSync()) return p;
      }
    }
  }
  return null;
}

class _Native {
  _Native(this._sign, this._verify);

  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _sign;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _verify;

  String sign(String secretHex, String digestHex, String auxHex) {
    final buf = malloc<Uint8>(32 * 3 + 64);
    try {
      _put(buf, 0, secretHex);
      _put(buf, 32, digestHex);
      _put(buf, 64, auxHex);
      if (_sign(buf, buf + 32, buf + 64, buf + 96) != 1) throw StateError('sign failed');
      return _hex(buf.asTypedList(160).sublist(96, 160));
    } finally {
      malloc.free(buf);
    }
  }

  bool verify(String keyHex, String digestHex, String signatureHex) {
    if (keyHex.length != 64 || digestHex.length != 64 || signatureHex.length != 128) return false;
    final buf = malloc<Uint8>(32 + 32 + 64);
    try {
      _put(buf, 0, keyHex);
      _put(buf, 32, digestHex);
      _put(buf, 64, signatureHex);
      return _verify(buf, buf + 32, buf + 64) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(buf);
    }
  }

  static void _put(Pointer<Uint8> buf, int at, String hex) {
    final bytes = buf.asTypedList(at + hex.length ~/ 2);
    for (var i = 0; i < hex.length ~/ 2; i++) {
      bytes[at + i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
  }

  static String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
