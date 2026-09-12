/// One JSON POST on a native build: dart:io's client.
library;

import 'dart:convert';
import 'dart:io';

/// The response body of a POST of [body] as JSON to [url], or null when
/// the answer is not 200.
Future<String?> postJson(Uri url, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return response.statusCode == 200 ? text : null;
  } finally {
    client.close(force: true);
  }
}
