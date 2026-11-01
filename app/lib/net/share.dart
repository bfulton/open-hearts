/// Sharing a link to a table: the platform's share sheet where there is
/// one, else the caller copies the link and says so.
library;

import '../pages.dart';
import 'address.dart';
import 'share_io.dart' if (dart.library.js_interop) 'share_web.dart' as platform;

/// The link to a room: the app's own address, and the room under it
/// (router.dart), whichever page this device is on.
Uri roomLink(String code, [Uri? base]) => pageLink(roomPath(code), base);

/// The link to a table: watched while it is played, and the game
/// itself once it is over (router.dart, review_page.dart).
Uri tableLink(String table, [Uri? base]) => pageLink(tablePath(table), base);

/// The link to one of the app's pages, [path] as router.dart has it.
Uri pageLink(String path, [Uri? base]) {
  final at = base ?? appBase();
  final root = at.path.endsWith('/') ? at.path : '${at.path}/';
  return Uri(scheme: at.scheme, host: at.host, port: at.hasPort ? at.port : null, path: '$root${path.substring(1)}');
}

/// Offers [url] through the platform's share sheet. True when it was
/// offered (taken or not); false where there is no sheet, so the
/// caller falls back to the clipboard.
Future<bool> shareLink(Uri url) => platform.shareLink(url.toString());

/// Opens [url] beside the app: a new tab on the web, the app it is for
/// on a phone. False where nothing opened, so the caller copies it
/// instead.
Future<bool> openBeside(Uri url) => platform.openBeside(url.toString());
