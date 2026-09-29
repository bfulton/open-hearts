/// The browser's address bar, written without loading anything.
///
/// `replaceState` rather than a push: entering and leaving a room is
/// not a place in the history, and a back button full of rooms nobody
/// visited would be worse than none.
library;

import 'dart:js_interop';

@JS('history')
external _History get _history;

extension type _History._(JSObject _) implements JSObject {
  external void replaceState(JSAny? data, JSString title, JSString? url);
}

void showAddress(String url) => _history.replaceState(null, ''.toJS, url.toJS);
