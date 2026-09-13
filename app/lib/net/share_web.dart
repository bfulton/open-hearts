/// The browser's share sheet, where it has one — phones do, and Safari
/// on a Mac; a desktop Chromium mostly does not.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('navigator')
external JSObject get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> share(JSObject data);
}

Future<bool> shareLink(String url) async {
  if (!_navigator.has('share')) return false;
  try {
    await _Navigator._(_navigator).share({'title': 'Open Hearts', 'url': url}.jsify() as JSObject).toDart;
    return true;
  } catch (_) {
    // Dismissed, or refused outside a tap: either way the sheet was the
    // answer, and copying would only surprise.
    return true;
  }
}
