/// The app's own requests on a native build: dart:io's client
/// (http.dart).
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

/// The body of a GET that was answered 200, or null.
Future<String?> getText(Uri url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    final body = await response.transform(utf8.decoder).join();
    return response.statusCode == 200 ? body : null;
  } finally {
    client.close(force: true);
  }
}
