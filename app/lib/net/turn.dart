/// ICE servers for a table.
///
/// Every data channel goes through TURN (net/mesh_transport.dart). The
/// credentials come from the service's turn-creds handler
/// (docs/explanation/service.md; service/functions/turn.mjs) — Cloudflare's
/// TURN in production, the rig's own on this machine — short-lived, and
/// fetched when a device connects so they are in hand when its table
/// starts. With none to give, a device makes no channels and its table
/// plays over the relay.
library;

import 'dart:convert';

import 'package:table/table.dart';

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

/// The ICE servers for this device's next table: from the handler at
/// [endpoint] (by default [turnEndpoint]); none when it has none, cannot
/// be reached, or there is no endpoint.
Future<List<Map<String, Object?>>> iceServersFor(Signer signer,
    {Uri? endpoint, Duration? timeout}) async {
  timeout ??= waits.turn;
  final url = endpoint ?? turnEndpoint();
  if (url == null) return const [];
  try {
    final body = await http.postJson(url, jsonEncode(signedAsk(signer, 'turn'))).timeout(timeout);
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
