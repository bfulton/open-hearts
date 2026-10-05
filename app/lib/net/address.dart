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

/// Where the app itself is: the address its page was served at, under
/// which every page's address sits (router.dart) — `/play/` on the site.
/// What a link to the app is made from, rather than the address of
/// whichever page happens to be showing.
Uri appBase() => platform.appBase();
