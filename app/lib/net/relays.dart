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
/// made with `--dart-define=DEV_RELAY=…` — the local rig against its
/// bridges — uses those, and a build served from localhost (`flutter
/// run`, the browser suite) uses the local relay (service/).
library;

import 'package:table/table.dart';

/// Our own relay, run for the game: the one a deployed build prefers
/// to write a table's events to while it is up, so the play rides
/// infrastructure we control and the volunteer relays are reach and
/// fallback. Baked into the build so it can be turned on without
/// releasing again; until it is up a build simply finds it down and
/// uses the others, which is why the same list is safe to ship now.
const homeRelay = 'wss://nostr.openhearts.game';

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

/// The local relay, where a build served from localhost looks.
const localRelay = 'ws://127.0.0.1:7447';

/// A dev loop's shortcut: a build made with `--dart-define=DEV_RELAY=…`
/// (a comma list) talks to those instead. Unset in a normal build.
const devRelay = String.fromEnvironment('DEV_RELAY');

/// The relays for this build, where it is served from.
List<Uri> appRelays({Uri? base}) {
  if (devRelay.isNotEmpty) return Relays.parse(devRelay);
  final host = (base ?? Uri.base).host;
  if (host == 'localhost' || host == '127.0.0.1' || host.isEmpty) return [Uri.parse(localRelay)];
  return [for (final r in publicRelays) Uri.parse(r)];
}
