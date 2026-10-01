/// ICE servers for a table.
///
/// Most pairs of players connect directly; the ten to twenty percent
/// behind a symmetric NAT or a strict firewall need a TURN relay
/// (docs/02-multiplayer.md), and without one they play over the relay
/// lane, which a public relay turned on once. TURN is Cloudflare's,
/// and its credentials come from the service's turn-creds handler
/// (docs/06-service.md; service/functions/worker.mjs), short-lived,
/// fetched when a device connects so they are in hand when its table
/// starts. When the handler has none to give — no TURN key configured
/// yet, or the handler unreachable — a STUN server that needs no
/// credentials still gives every peer its public address. On
/// localhost there is nothing: peers connect directly (doc 06, local
/// mode), and the browser suite stays off the network.
library;

import 'dart:convert';

import 'package:table/table.dart';

import 'licence.dart' show signedAsk;
import 'turn_fetch_io.dart' if (dart.library.js_interop) 'turn_fetch_web.dart' as http;

/// Where credentials come from: the app's origin over https — the site
/// the worker runs beside — else nowhere.
Uri? turnEndpoint() {
  final base = Uri.base;
  if (base.scheme != 'https' || base.host.isEmpty) return null;
  return Uri(scheme: 'https', host: base.host, port: base.hasPort ? base.port : null, path: '/api/turn');
}

/// Cloudflare's STUN, free and without credentials.
const stunOnly = <Map<String, Object?>>[
  {
    'urls': ['stun:stun.cloudflare.com:3478']
  },
];

/// The ICE servers for this device's next table: from the handler at
/// [endpoint] (by default [turnEndpoint]), [stunOnly] when it has none
/// or cannot be reached, none when there is no endpoint.
Future<List<Map<String, Object?>>> iceServersFor(Signer signer,
    {Uri? endpoint, Duration timeout = const Duration(seconds: 5)}) async {
  final url = endpoint ?? turnEndpoint();
  if (url == null) return const [];
  try {
    final body = await http.postJson(url, jsonEncode(signedAsk(signer, 'turn'))).timeout(timeout);
    if (body == null) return stunOnly;
    return parseIceServers(body) ?? stunOnly;
  } catch (_) {
    return stunOnly;
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
