/// The room's link, in the browser's address bar.
///
/// The code is nobody's to type and is shown nowhere: the link is the
/// way in. So while this device is in a room the address bar is where
/// that room lives — a refresh comes back to it, and the address is
/// there to copy for anyone who would rather copy than share. Off the
/// web there is no address bar, as there is no share sheet
/// (share.dart), and this does nothing.
library;

import 'address_io.dart' if (dart.library.js_interop) 'address_web.dart' as platform;

/// How long a room waits for one more arrival before its leader starts
/// it, as this address asks for it.
///
/// Ten seconds is right for people, who open a link in about one. The
/// four-browser suite opens four whole apps on one machine, where that
/// can take as long as the window itself — so the last of them arrives
/// at a table that has already begun without it, and the suite fails
/// for a reason that has nothing to do with the game. It asks for
/// longer instead: `?e2e=1&roomWait=45`. Four in a room is still a
/// table at once, whatever the wait; all a longer one does is stop a
/// room starting short.
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

/// Puts the room under [code] in the address bar, or takes a room out
/// of it when [code] is null.
void showRoom(String? code) => platform.showAddress(roomAddress(code, Uri.base));

/// Takes [name] out of the address and leaves the rest of it alone:
/// for a mark a round trip put there — the `bought` a checkout comes
/// back with — which a refresh should not act on twice.
void forgetInAddress(String name) => platform.showAddress(addressWithout(name, Uri.base));

String addressWithout(String name, Uri at) {
  final params = Map<String, String>.from(at.queryParameters)..remove(name);
  return Uri(
    path: at.path.isEmpty ? '/' : at.path,
    queryParameters: params.isEmpty ? null : params,
    fragment: at.fragment.isEmpty ? null : at.fragment,
  ).toString();
}

/// What the address becomes: [at] with the room set or dropped, and
/// the rest of it left alone — a build driven with `?e2e` stays driven
/// with it across a refresh.
String roomAddress(String? code, Uri at) {
  final params = Map<String, String>.from(at.queryParameters)..remove('room');
  if (code != null) params['room'] = code;
  return Uri(
    // An empty path would leave the address where it is, query and all.
    path: at.path.isEmpty ? '/' : at.path,
    queryParameters: params.isEmpty ? null : params,
    fragment: at.fragment.isEmpty ? null : at.fragment,
  ).toString();
}
