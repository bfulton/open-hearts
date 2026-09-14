/// The page the app is served in. It is hand-written rather than
/// Flutter's template, so the one line the template has for a reason —
/// the viewport — is checked here: without it a phone lays the page out
/// at its default 980 points and scales it down, which is desktop mode,
/// and a page that can be pinched and panned moves what you see away
/// from where the app thinks you touched.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the page asks for the device\'s width and no zoom of the browser\'s', () {
    final head = File('web/index.html').readAsStringSync();
    final meta = RegExp(r'<meta name="viewport" content="([^"]*)">').firstMatch(head);
    expect(meta, isNotNull, reason: 'no viewport meta: the app would be laid out as a desktop page');
    final content = meta!.group(1)!;
    expect(content, contains('width=device-width'));
    expect(content, contains('user-scalable=no'), reason: 'a canvas that does its own scaling must not be pinch-zoomed');
    expect(content, isNot(contains('viewport-fit=cover')),
        reason: 'Flutter web does not read the safe-area insets, so the browser keeps the page clear of the notch');
  });
}
