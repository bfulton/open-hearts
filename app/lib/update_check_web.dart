/// Web implementation of the deployed-build check.
///
/// A bare `fetch` rather than a package: the whole job is one no-store
/// GET of a small JSON file next to index.html, and a dependency for
/// that would be the larger cost.
library;

import 'dart:convert';
import 'dart:js_interop';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, JSObject init);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSString> text();
}

/// `?updatecheck` turns the pill on for a build that was not deployed —
/// the escape hatch that lets the pill itself be exercised by hand.
bool get forcedByQuery =>
    Uri.base.queryParameters.containsKey('updatecheck');

Future<String?> publishedBuild() async {
  try {
    // Cache-busted twice over: the query defeats any intermediary that
    // ignores no-store, and no-store defeats the browser's own cache.
    final url = 'build-info.json?t=${DateTime.now().millisecondsSinceEpoch}';
    final init = {'cache': 'no-store'}.jsify() as JSObject;
    final response = await _fetch(url.toJS, init).toDart;
    if (!response.ok) return null;
    final body = (await response.text().toDart).toDart;
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
