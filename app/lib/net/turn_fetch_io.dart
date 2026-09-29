/// One JSON POST on a native build: dart:io's client.
library;

import 'dart:convert';
import 'dart:io';

/// The answer to a POST of [body] as JSON to [url], whatever it says.
/// A refusal carries its reason, which is often the thing worth
/// showing.
Future<({int status, String body})> post(Uri url, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    return (status: response.statusCode, body: await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

/// The body of a POST that was taken, or null when it was not.
Future<String?> postJson(Uri url, String body) async {
  final answer = await post(url, body);
  return answer.status == 200 ? answer.body : null;
}
