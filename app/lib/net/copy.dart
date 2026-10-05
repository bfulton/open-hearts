/// Text onto the clipboard, in a way every platform allows.
///
/// A phone build uses the system clipboard as any app does. The web
/// build goes through the page (web/copy.js), because Safari refuses a
/// clipboard write that does not happen during the tap itself, and the
/// app's own handling of a tap ends too late for it.
library;

import 'copy_io.dart' if (dart.library.js_interop) 'copy_web.dart' as platform;

Future<void> copyText(String text) => platform.copyText(text);
