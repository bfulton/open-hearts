/// Text onto the clipboard, and off it, in a way every platform allows.
///
/// A phone build uses the system clipboard as any app does. The web
/// build goes through the page (web/copy.js), because Safari refuses a
/// clipboard write that does not happen during the tap itself, and the
/// app's own handling of a tap ends too late for it.
library;

import 'copy_io.dart' if (dart.library.js_interop) 'copy_web.dart' as platform;

Future<void> copyText(String text) => platform.copyText(text);

/// The clipboard's text, or null when it cannot be read (the person can
/// still paste by hand, into the field).
Future<String?> pasteText() => platform.pasteText();
