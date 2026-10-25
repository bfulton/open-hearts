/// The relays a device talks to: a constant of the build, not a setting.
///
/// A deployed build talks to our relay and nothing else
/// (docs/explanation/relay.md): one Cloudflare object per tag
/// (`service/do/`) — a table, its signalling, a pool's waiting room, a
/// room code, the results, presence — named in the address before the
/// socket is opened. The deployed site and production run the same
/// list. Two exceptions, both decided when the build is made, never on
/// the page: a build made with `--dart-define=OH_RELAYS=…` uses those —
/// a preview, the preview relay (deploy.sh), and the local rig, its
/// bridges — and a build served from localhost (`flutter run`, the
/// browser suite) uses the local relay (service/), at the port its
/// address names if it names one. The remote config may name another
/// relay of ours (net/remote_config.dart), never anyone else's.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:table/table.dart';

import 'address.dart' show isLocalHost;
import 'remote_config.dart';

/// Our relay: a Cloudflare object per tag, which is why the tag is in
/// the URL. The mark is `tagMark` (`packages/table`, presence_relay.dart);
/// whoever opens a socket for a tag puts the tag there.
const ourRelay = 'wss://relay.openhearts.game/{tag}';

/// The relays a deployed build starts on: ours.
const deployedRelays = [ourRelay];

/// How many relays at the front of [relays] are ours, kept first in
/// every table's rotation. All of a deployed list; none of a local one.
int pinnedRelays(List<Uri> relays) => relays.takeWhile(RemoteConfig.ours).length;

/// The local relay, where a build served from this machine looks.
const localRelay = 'ws://127.0.0.1:7447';

/// The local relay at the port the address names (`?relay=7448`), and
/// at [localRelay]'s otherwise: each browser suite on a machine starts
/// its relay on a port of its own (e2e/drive.mjs), so two can run side
/// by side. A port and nothing more, so the address can move a local
/// build to another relay on this machine and nowhere else; and only
/// ever read for a build served from this machine ([appRelays]).
Uri localRelayAt(Uri at) {
  final port = int.tryParse(at.queryParameters['relay'] ?? '');
  final local = Uri.parse(localRelay);
  return port == null || port < 1 || port > 65535 ? local : local.replace(port: port);
}

/// A build made with `--dart-define=OH_RELAYS=…` (a comma list) talks to
/// those instead: a preview's, the preview relay (deploy.sh), and the
/// dev loop's, its bridges. Unset in production's.
const devRelay = String.fromEnvironment('OH_RELAYS');

/// The relays for this build, where it is served from: the operator's,
/// when the remote config names some (net/remote_config.dart), and the
/// build's own otherwise. A preview, a local build and the rig keep
/// theirs whatever the config says — they are not on anyone's relays
/// but their own.
///
/// A phone build has no address it was served from, and is a deployed
/// build like the site's, not a local one.
List<Uri> appRelays({Uri? base, RemoteConfig? config, bool web = kIsWeb}) {
  if (devRelay.isNotEmpty) return Relays.parse(devRelay);
  final at = base ?? Uri.base;
  if (web && (isLocalHost(at.host) || at.host.isEmpty)) return [localRelayAt(at)];
  final named = (config ?? RemoteSettings.current.config).relays;
  if (named != null) return named;
  return [for (final r in deployedRelays) Uri.parse(r)];
}
