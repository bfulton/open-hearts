/// The relays a device talks to: a constant of the build, not a setting.
///
/// A deployed build carries a few public relays and uses them together —
/// listened on all, written to one at a time, the next one tried when a
/// relay refuses (packages/table, relays.dart) — so that one relay
/// turning on a table is not the end of it, and so that nobody has to
/// know what a relay is to sit down. Two exceptions, both decided when
/// the build is made, never on the page: a dev build made with
/// `--dart-define=DEV_RELAY=…` uses those, and a build served from
/// localhost — `flutter run`, the browser suite — uses the local relay
/// (service/) at its usual port.
library;

import 'package:table/table.dart';

/// The public relays a deployed build starts on.
const publicRelays = [
  'wss://relay.damus.io',
  'wss://relay.primal.net',
  'wss://nos.lol',
];

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
