/// BIP-340 signatures through the native cdylib in crypto/schnorr, for
/// the Dart VM: the house checks every event of every table it
/// serves, and at seventeen milliseconds a signature in
/// pure Dart a table's traffic would be most of a core. The same k256 the
/// browser's wasm uses, two hundred times faster.
library;

export 'schnorr_native_vm.dart' if (dart.library.js_interop) 'schnorr_native_web.dart';
