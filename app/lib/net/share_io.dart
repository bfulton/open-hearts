/// No share sheet off the web yet: the clipboard it is. An address
/// opens in the app it is for: the browser for a page, the mail app for
/// a mailto.
library;

import 'package:url_launcher/url_launcher.dart';

Future<bool> shareLink(String url) async => false;

/// False when no app on the device takes [url].
Future<bool> openBeside(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
