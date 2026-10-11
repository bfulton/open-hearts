/// The app's own small requests to the service: a JSON POST, and a GET
/// of text. Not a general client: what each answer means is the
/// caller's.
library;

import 'http_io.dart' if (dart.library.js_interop) 'http_web.dart' as platform;

/// The answer to a POST of [body] as JSON to [url], whatever it says.
/// A refusal carries its reason, which is often the thing worth
/// showing.
Future<({int status, String body})> post(Uri url, String body) => platform.post(url, body);

/// The body of a POST that was taken, or null when it was not.
Future<String?> postJson(Uri url, String body) async {
  final answer = await post(url, body);
  return answer.status == 200 ? answer.body : null;
}

/// The body of a GET that was answered 200, or null.
Future<String?> getText(Uri url) => platform.getText(url);
