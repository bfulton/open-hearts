/// ICE servers for a call between seats.
///
/// Nothing of a game goes over WebRTC: a table is played on its line to
/// its referee (packages/table, relay_line.dart). This is kept for the
/// voice and video chat among friends that is planned (ROADMAP.md),
/// where every channel is to go through TURN and nowhere else, so that
/// nobody at a table learns another's address. The credentials come
/// from the service's `turn` handler (docs/explanation/service.md;
/// service/functions/turn.mjs) — Cloudflare's TURN in production, the
/// rig's own on this machine — short-lived, and fetched when they are
/// wanted. With none to give, there are none.
library;

import 'dart:convert';

import 'package:table/table.dart';

import '../entitlement.dart';
import 'address.dart' show appBase, isLocalHost;
import 'http.dart' as http;
import 'licence.dart' show signedAsk;
import 'remote_config.dart' show waits;

/// Where credentials come from: the app's own origin — the site the
/// worker runs beside, over https, or the browser rig on this machine
/// (e2e/drive.mjs), or on a phone the address its build names — else
/// nowhere.
Uri? turnEndpoint([Uri? at]) {
  final base = at ?? appBase();
  final local = base.scheme == 'http' && isLocalHost(base.host);
  if ((base.scheme != 'https' && !local) || base.host.isEmpty) return null;
  return Uri(scheme: base.scheme, host: base.host, port: base.hasPort ? base.port : null, path: '/api/turn');
}

/// The ICE servers for a call: from the handler at
/// [endpoint] (by default [turnEndpoint]); none when it has none, cannot
/// be reached, or there is no endpoint.
Future<List<Map<String, Object?>>> iceServersFor(Signer signer,
    {Uri? endpoint, Duration? timeout}) async {
  timeout ??= waits.turn;
  final url = endpoint ?? turnEndpoint();
  if (url == null) return const [];
  try {
    // With the licence this device holds, as every ask of the service
    // shows it (household.dart, askHandler).
    final asked = {...signedAsk(signer, 'turn'), ...Entitlement.current.licenceShown};
    final body = await http.postJson(url, jsonEncode(asked)).timeout(timeout);
    if (body == null) return const [];
    return parseIceServers(body) ?? const [];
  } catch (_) {
    return const [];
  }
}

/// The handler's answer as the list a peer connection takes; null when
/// it is not one.
List<Map<String, Object?>>? parseIceServers(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final list = json['iceServers'];
    if (list is! List) return null;
    final servers = <Map<String, Object?>>[];
    for (final s in list) {
      if (s is! Map) continue;
      final urls = s['urls'];
      final u = urls is List ? [for (final x in urls) if (x is String) x] : urls is String ? [urls] : const <String>[];
      if (u.isEmpty) continue;
      servers.add({
        'urls': u,
        if (s['username'] is String) 'username': s['username'],
        if (s['credential'] is String) 'credential': s['credential'],
      });
    }
    return servers.isEmpty ? null : servers;
  } catch (_) {
    return null;
  }
}
