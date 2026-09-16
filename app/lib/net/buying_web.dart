/// Leaving the app for a checkout, in a browser.
library;

import 'dart:js_interop';

@JS('location')
external _Location get _location;

extension type _Location._(JSObject _) implements JSObject {
  external void assign(JSString url);
}

/// The web can be sent to a checkout and brought back by it.
const canLeaveForCheckout = true;

/// A load rather than a push: the app is being left, and the way back
/// is Stripe's redirect, not the back button.
void leaveFor(String url) => _location.assign(url.toJS);
