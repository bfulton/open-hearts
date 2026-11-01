/// The app's own requests on the web (http.dart), and the update
/// check's (update_check_web.dart): a bare `fetch`.
library;

import 'dart:js_interop';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, JSObject init);

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external JSPromise<JSString> text();
}

/// The answer to a POST of [body] as JSON to [url], whatever it says.
/// A refusal carries its reason, which is often the thing worth
/// showing.
Future<({int status, String body})> post(Uri url, String body) async {
  final init = {
    'method': 'POST',
    'headers': {'content-type': 'application/json'},
    'body': body,
    'cache': 'no-store',
  }.jsify() as JSObject;
  final response = await _fetch(url.toString().toJS, init).toDart;
  return (status: response.status, body: (await response.text().toDart).toDart);
}

/// The body of a GET that was answered 200, or null. The browser's own
/// cache is let in, so an answer that says how long it keeps is kept
/// that long; with [noStore], the cache is neither read nor written.
Future<String?> getText(Uri url, {bool noStore = false}) async {
  final init = {'method': 'GET', if (noStore) 'cache': 'no-store'}.jsify() as JSObject;
  final response = await _fetch(url.toString().toJS, init).toDart;
  if (response.status != 200) return null;
  return (await response.text().toDart).toDart;
}
