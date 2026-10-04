import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// The page's account of the last touches and of its own size
/// (web/touch_probe.js), as JSON; null where the page has no probe.
String? pageTouches() {
  if (!globalContext.has('ohTouchProbe')) return null;
  return (globalContext.callMethod<JSString>('ohTouchProbe'.toJS)).toDart;
}
