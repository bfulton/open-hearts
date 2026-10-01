/// Sharing a link to a table: the platform's share sheet where there is
/// one, else the caller copies the link and says so.
library;

import 'share_io.dart' if (dart.library.js_interop) 'share_web.dart' as platform;

/// The link to a room: this app's own address, with the code.
Uri roomLink(String code) => Uri.base.removeFragment().replace(queryParameters: {'room': code});

/// Offers [url] through the platform's share sheet. True when it was
/// offered (taken or not); false where there is no sheet, so the
/// caller falls back to the clipboard.
Future<bool> shareLink(Uri url) => platform.shareLink(url.toString());

/// Opens [url] beside the app — a new tab on the web. False where
/// nothing can be opened, so the caller copies it instead.
bool openBeside(Uri url) => platform.openBeside(url.toString());
