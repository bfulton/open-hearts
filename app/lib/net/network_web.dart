/// The browser's own word on the network: `navigator.onLine`, which is
/// false in airplane mode and with no connection at all, and true
/// otherwise — on a network that reaches nothing as well, which is why
/// only false is taken at its word (network.dart).
library;

import 'dart:js_interop';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external bool get onLine;
}

bool offline() => !_navigator.onLine;

@JS('addEventListener')
external void _addEventListener(JSString type, JSFunction listener);

void whenOnline(void Function() then) => _addEventListener('online'.toJS, ((JSAny? _) => then()).toJS);
