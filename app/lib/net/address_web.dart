/// The page's base address, as the browser resolved it: `<base href>`.
library;

import 'dart:js_interop';

@JS('document.baseURI')
external JSString get _baseUri;

Uri appBase() => Uri.parse(_baseUri.toDart);
