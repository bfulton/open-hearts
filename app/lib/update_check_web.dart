/// Web implementation of the deployed-build check: one no-store GET of
/// the small JSON file next to index.html.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'net/http_web.dart' as http;

/// `?updatecheck` turns the pill on for a build that was not deployed —
/// the escape hatch that lets the pill itself be exercised by hand.
bool get forcedByQuery =>
    Uri.base.queryParameters.containsKey('updatecheck');

Future<String?> publishedBuild() async {
  try {
    // Cache-busted twice over: the query defeats any intermediary that
    // ignores no-store, and no-store defeats the browser's own cache.
    final url = Uri.parse('build-info.json?t=${DateTime.now().millisecondsSinceEpoch}');
    final body = await http.getText(url, noStore: true);
    if (body == null) return null;
    final json = jsonDecode(body);
    return json is Map && json['build'] is String
        ? json['build'] as String
        : null;
  } catch (_) {
    // Offline, a 404 between deploys, a proxy serving HTML: all the same
    // answer — we do not know, so say nothing.
    return null;
  }
}

@JS('location')
external _Location get _location;

extension type _Location._(JSObject _) implements JSObject {
  external void reload();
}

/// Hard-reloads onto the newly published build.
void reloadPage() => _location.reload();
