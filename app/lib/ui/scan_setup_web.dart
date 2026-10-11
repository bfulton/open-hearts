/// Which reader a browser scans with. Its own BarcodeDetector where it
/// has one that reads QR codes (Chrome on Android and a Mac, Safari
/// 17+); elsewhere ZXing's JavaScript port, served from this site
/// (web/zxing) rather than fetched from somebody's CDN at the moment a
/// person points their camera.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:mobile_scanner/mobile_scanner.dart';

/// The ZXing build in web/zxing, beside the app.
const zxingScript = 'zxing/zxing-library-0.23.0.min.js';

@JS('document.baseURI')
external JSString get _baseUri;

extension type _Detector._(JSObject _) implements JSObject {
  external JSPromise<JSArray<JSString>> getSupportedFormats();
}

Future<bool> _detectsQr() async {
  if (!globalContext.has('BarcodeDetector')) return false;
  try {
    final formats = await _Detector._(globalContext['BarcodeDetector'] as JSObject).getSupportedFormats().toDart;
    return formats.toDart.any((f) => f.toDart == 'qr_code');
  } catch (_) {
    return false;
  }
}

Future<void> prepareScanner() async {
  final platform = MobileScannerPlatform.instance;
  if (await _detectsQr()) {
    platform.setWebBarcodeReader(WebBarcodeReader.barcodeDetector);
    return;
  }
  platform.setWebBarcodeReader(WebBarcodeReader.zxingJs);
  platform.setBarcodeLibraryScriptUrl(Uri.parse(_baseUri.toDart).resolve(zxingScript).toString());
}
