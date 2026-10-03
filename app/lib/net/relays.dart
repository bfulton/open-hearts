/// The relays a device talks to: a constant of the build, not a setting.
///
/// A deployed build talks to our relay and nothing else
/// (docs/08-own-relays.md): one Cloudflare object per tag
/// (`service/do/`) — a table, its signalling, a pool's waiting room, a
/// room code, the results, presence — named in the address before the
/// socket is opened. The deployed site and production run the same
/// list. Two exceptions, both decided when the build is made, never on
/// the page: a build made with `--dart-define=OH_RELAYS=…` — the local
/// rig against its bridges — uses those, and a build served from
/// localhost (`flutter run`, the browser suite) uses the local relay
/// (service/). The remote config may name another relay of ours
/// (net/remote_config.dart), never anyone else's.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:table/table.dart';

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

/// The relays presence talks on: the same as everything else's now.
List<Uri> presenceRelays(List<Uri> relays) => relays;

/// The local relay, where a build served from localhost looks.
const localRelay = 'ws://127.0.0.1:7447';

/// A dev loop's shortcut: a build made with `--dart-define=OH_RELAYS=…`
/// (a comma list) talks to those instead. Unset in a normal build.
const devRelay = String.fromEnvironment('OH_RELAYS');

/// The relays for this build, where it is served from: the operator's,
/// when the remote config names some (net/remote_config.dart), and the
/// build's own otherwise. A local build and the rig keep theirs whatever
/// the config says — they are not on anyone's relays but their own.
///
/// A phone build has no address it was served from, and is a deployed
/// build like the site's: it was taken for a local one, and would have
/// looked for a relay on the phone itself.
List<Uri> appRelays({Uri? base, RemoteConfig? config, bool web = kIsWeb}) {
  if (devRelay.isNotEmpty) return Relays.parse(devRelay);
  final host = (base ?? Uri.base).host;
  if (web && (host == 'localhost' || host == '127.0.0.1' || host.isEmpty)) return [Uri.parse(localRelay)];
  final named = (config ?? RemoteSettings.current.config).relays;
  if (named != null) return named;
  return [for (final r in deployedRelays) Uri.parse(r)];
}
