import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';

/// The clipboard's text, through the page (web/copy.js), which reads it
/// in the browser's own touchend or click; the framework's clipboard
/// where the page has none. Null when it cannot be read.
Future<String?> pasteText() async {
  if (!globalContext.has('ohPaste')) return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  try {
    final read = await globalContext.callMethod<JSPromise<JSString?>>('ohPaste'.toJS).toDart;
    return read?.toDart;
  } catch (_) {
    return null;
  }
}

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
