/// One JSON POST on the web: a bare `fetch`, as the update check does.
library;

import 'dart:js_interop';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, JSObject init);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
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

/// The body of a POST that was taken, or null when it was not.
Future<String?> postJson(Uri url, String body) async {
  final answer = await post(url, body);
  return answer.status == 200 ? answer.body : null;
}
