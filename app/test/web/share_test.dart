/// On a page (flutter test --platform chrome): a link opened beside the
/// app opens in a tab cut off from it, and a blocked pop-up is said to
/// be, so the caller copies the link instead.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/share.dart';

void main() {
  test('opened: cut off from the app before it goes to the link; blocked: false', () {
    final real = globalContext['open'];
    addTearDown(() => globalContext['open'] = real);

    final asked = <String>[];
    final tab = JSObject()..['opener'] = globalContext;
    globalContext['open'] = ((JSString url, JSString target) {
      asked.add('${url.toDart} ${target.toDart}');
      return tab;
    }).toJS;
    expect(openBeside(Uri.parse('https://github.com/bfulton/open-hearts/issues/new?title=x')), isTrue);
    expect(asked, [' _blank'], reason: 'opened empty, so nothing loads before it is cut off');
    expect(tab['opener'], isNull);
    expect((tab['location'] as JSString).toDart, 'https://github.com/bfulton/open-hearts/issues/new?title=x');

    // A blocked pop-up: window.open answers null.
    globalContext['open'] = ((JSString url, JSString target) => null).toJS;
    expect(openBeside(Uri.parse('https://github.com/bfulton/open-hearts/issues/new')), isFalse);
  });
}
