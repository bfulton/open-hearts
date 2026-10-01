/// The relays a device talks to: a constant of the build, not a setting.
///
/// A deployed build carries our own relay and a few public ones and
/// uses them together — listened on all, a table's events written to
/// the first everyone reads and our own preferred while it is up, what
/// forms a room and what goes unanswered to all (packages/table,
/// relays.dart) — so that one relay turning on a table is not the end
/// of it, and so that nobody has to know what a relay is to sit down.
/// The deployed site and production run the same list. Two exceptions,
/// both decided when the build is made, never on the page: a build
/// made with `--dart-define=OH_RELAYS=…` — the local rig against its
/// bridges — uses those, and a build served from localhost (`flutter
/// run`, the browser suite) uses the local relay (service/).
library;

import 'package:table/table.dart';

import 'remote_config.dart';

/// Our own relay, run for the game: the one a deployed build prefers
/// to write a table's events to while it is up, so the play rides
/// infrastructure we control and the volunteer relays are reach and
/// fallback. Baked into the build so it can be turned on without
/// releasing again; until it is up a build simply finds it down and
/// uses the others, which is why the same list is safe to ship now.
const homeRelay = 'wss://nostr.openhearts.game';

/// Our own relay again, and the one presence is carried on: a
/// Cloudflare object per tag (docs/06-service.md, `service/do/`),
/// which is why the tag is in the URL — the object has to be named
/// before the socket is opened. The mark is `tagMark`
/// (`packages/table`, presence_relay.dart) and the client that has a
/// tag puts it there; a client with none cannot use this relay at
/// all, which is why it is in the presence list and not in the one
/// tables and signalling take.
///
/// It is preferred for what it carries and it is not relied on. Every
/// beat still goes to the public relays as well, because a device is
/// online for whoever can hear it and we do not get to assume what
/// another device can reach — so the day this object is down, or has
/// never been deployed, presence is exactly what it was before it
/// existed.
const homeTagRelay = 'wss://relay.openhearts.game/{tag}';

/// The relays a deployed build starts on: our own first, then a few
/// public ones. The deployed site and production use this same list.
const publicRelays = [
  homeRelay,
  'wss://relay.damus.io',
  'wss://relay.primal.net',
  'wss://nos.lol',
];

/// How many relays at the front of [relays] are ours to run — kept
/// first in every table's rotation, primary while up. The home relay
/// leads a deployed build's list; a local or rig list has none of ours.
int pinnedRelays(List<Uri> relays) =>
    relays.isNotEmpty && relays.first.toString() == homeRelay ? 1 : 0;

/// The relays presence talks on: our per-tag object in front of the
/// list everything else uses. A build that is not on our relays at
/// all — a local one, or the rig against its bridges — has no object
/// of ours to reach and takes the list as it stands.
///
/// This is the list [RelayPresence] and the juror's duty want
/// (`app/lib/net/duty.dart`); [appRelays] stays what a table, its
/// signalling and the standings are written to, since a table has not
/// moved to the object and would have nowhere to put its tag.
List<Uri> presenceRelays(List<Uri> relays) =>
    pinnedRelays(relays) == 0 ? relays : [Uri.parse(homeTagRelay), ...relays];

/// The local relay, where a build served from localhost looks.
const localRelay = 'ws://127.0.0.1:7447';

/// A dev loop's shortcut: a build made with `--dart-define=OH_RELAYS=…`
/// (a comma list) talks to those instead. Unset in a normal build.
const devRelay = String.fromEnvironment('OH_RELAYS');

/// The relays for this build, where it is served from: the operator's,
/// when the remote config names some (net/remote_config.dart), and the
/// build's own otherwise. A local build and the rig keep theirs whatever
/// the config says — they are not on anyone's relays but their own.
List<Uri> appRelays({Uri? base, RemoteConfig? config}) {
  if (devRelay.isNotEmpty) return Relays.parse(devRelay);
  final host = (base ?? Uri.base).host;
  if (host == 'localhost' || host == '127.0.0.1' || host.isEmpty) return [Uri.parse(localRelay)];
  final named = (config ?? RemoteSettings.current.config).relays;
  if (named != null) return named;
  return [for (final r in publicRelays) Uri.parse(r)];
}
