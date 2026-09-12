/// One JSON POST on the web: a bare `fetch`, as the update check does.
library;

import 'dart:js_interop';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, JSObject init);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSString> text();
}

/// The response body of a POST of [body] as JSON to [url], or null when
/// the answer is not 200.
Future<String?> postJson(Uri url, String body) async {
  final init = {
    'method': 'POST',
    'headers': {'content-type': 'application/json'},
    'body': body,
    'cache': 'no-store',
  }.jsify() as JSObject;
  final response = await _fetch(url.toString().toJS, init).toDart;
  if (!response.ok) return null;
  return (await response.text().toDart).toDart;
}
