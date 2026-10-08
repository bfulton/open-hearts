/// The app's address, as far as the app needs to know it: where it was
/// served from, and how long a room waits as the address asks. Which
/// page is showing is the router's (router.dart).
library;

import 'address_io.dart' if (dart.library.js_interop) 'address_web.dart' as platform;

/// How long a room waits for one more arrival before its leader starts
/// it, as this address asks for it.
///
/// Ten seconds is right for people, who open a link in about one. The
/// four-browser suite opens four whole apps on one machine, which can
/// take as long as the window itself, so it asks for longer:
/// `?e2e=1&roomWait=45`. Four in a room is still a table at once,
/// whatever the wait; all a longer one does is stop a room starting
/// short.
///
/// Only under `?e2e`, which is the address saying this build is being
/// driven rather than played, and never shorter than [standard] nor
/// longer than [most]. It is one device's read of a shared clock — the
/// leader's is the one that counts — so the most it can do to anyone
/// else's room is make it wait a minute for a fourth, which is what
/// the leader's own Start now is there to cut short.
Duration roomWait(Uri at, {required Duration standard, Duration most = const Duration(minutes: 1)}) {
  if (!at.queryParameters.containsKey('e2e')) return standard;
  final asked = int.tryParse(at.queryParameters['roomWait'] ?? '');
  if (asked == null) return standard;
  return Duration(seconds: asked.clamp(standard.inSeconds, most.inSeconds));
}

/// How much of its beats a table takes, as this address asks: all of
/// them, unless the address is under `?e2e` and asks for a share
/// (`?e2e=1&pace=0.1`), never less than a tenth. The browser suites
/// play hands by the dozen, and a bot's thinking and a trick held on
/// the felt are most of a hand's minute; at a tenth the same beats come
/// in the same order, and the widget tests hold them to their lengths
/// (game_controller_test.dart).
double paceIn(Uri at) {
  if (!at.queryParameters.containsKey('e2e')) return 1;
  final asked = double.tryParse(at.queryParameters['pace'] ?? '');
  if (asked == null || asked.isNaN) return 1;
  return asked.clamp(0.1, 1.0);
}

/// The score the games this device starts play to, when the address
/// says, under `?e2e`: a suite that has to see a game's end does not
/// need fifty points of it (`?e2e=1&target=1`, a game of one hand).
/// Null otherwise, and the device's own choice stands (game_options.dart).
int? targetIn(Uri at) {
  if (!at.queryParameters.containsKey('e2e')) return null;
  final asked = int.tryParse(at.queryParameters['target'] ?? '');
  return asked == null || asked < 1 || asked > 100 ? null : asked;
}

/// Whether [host] is this machine: `localhost`, `127.0.0.1`, or a name
/// under `.localhost`, which a browser takes to be this machine too. The
/// browser rig serves the site at openhearts.localhost and the app at
/// play.openhearts.localhost (e2e/drive.mjs), as production serves them
/// at openhearts.game and play.openhearts.game.
bool isLocalHost(String host) => host == 'localhost' || host == '127.0.0.1' || host.endsWith('.localhost');

/// Where the app itself is: the address its page was served at, under
/// which every page's address sits (router.dart) — the root of
/// play.openhearts.game, or `/play/` on a preview of the site.
/// What a link to the app is made from, rather than the address of
/// whichever page happens to be showing.
Uri appBase() => platform.appBase();
