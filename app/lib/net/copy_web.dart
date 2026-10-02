import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';

/// Through the page's own copier (web/copy.js), which also writes the
/// text in the browser's next touchend or click; the framework's
/// clipboard where the page has none.
Future<void> copyText(String text) async {
  if (!globalContext.has('ohCopy')) return Clipboard.setData(ClipboardData(text: text));
  final written = globalContext.callMethod<JSAny?>('ohCopy'.toJS, text.toJS);
  if (written != null && written.isA<JSPromise>()) {
    try {
      await (written as JSPromise).toDart;
    } catch (_) {
      // Refused now; the page writes it again in the tap's own event.
    }
  }
}
