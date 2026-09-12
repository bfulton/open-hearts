/// The web has its own wasm (the app's crypto/schnorr_web.dart); there
/// is no cdylib to load.
library;

Future<bool> installNativeSchnorr({String? libraryPath}) async => false;
