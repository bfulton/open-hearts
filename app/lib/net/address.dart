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

/// Puts the room under [code] in the address bar, or takes a room out
/// of it when [code] is null.
void showRoom(String? code) => platform.showAddress(roomAddress(code, Uri.base));

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
