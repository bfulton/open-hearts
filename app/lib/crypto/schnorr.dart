/// BIP-340 signing for this platform.
///
/// The VM and the phones sign with the pure-Dart `bip340` package via
/// the table package; the web signs and verifies through a small wasm,
/// two hundred times faster there (measurements/sign). Same keys, same
/// signatures, one interface.
library;

export 'schnorr_vm.dart' if (dart.library.js_interop) 'schnorr_web.dart';
