/// The browser's share sheet, where it has one — phones do, and Safari
/// on a Mac; a desktop Chromium mostly does not.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('navigator')
external JSObject get _navigator;

@JS('open')
external JSObject? _open(JSString url, JSString target);

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

/// A new tab, cut off from this one: the page opened cannot reach back
/// into the app's window. False when no tab opened — a blocked pop-up,
/// which Safari on a phone blocks by default — so the caller copies
/// instead. Opened empty and cut off before it goes anywhere: with
/// `noopener` asked for, the browser answers null whether it opened
/// one or not, and a blocked tab would look like an opened one. It
/// opens before anything is awaited, inside the tap that asked, which a
/// browser requires of a new tab.
Future<bool> openBeside(String url) async {
  final tab = _open(''.toJS, '_blank'.toJS);
  if (tab == null) return false;
  tab['opener'] = null;
  tab['location'] = url.toJS;
  return true;
}
