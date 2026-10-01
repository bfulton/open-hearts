/// The page the app is served in, the manifest it is installed from,
/// and the bootstrap that keeps it for a load with no network
/// (offline_worker.js). The page is hand-written rather than Flutter's template, so
/// the one line the template has for a reason — the viewport — is
/// checked here: without it a phone lays the page out at its default
/// 980 points and scales it down, which is desktop mode.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the page asks for the device\'s width, and lets the reader zoom it', () {
    final head = File('web/index.html').readAsStringSync();
    final meta = RegExp(r'<meta name="viewport" content="([^"]*)">').firstMatch(head);
    expect(meta, isNotNull, reason: 'no viewport meta: the app would be laid out as a desktop page');
    final content = meta!.group(1)!;
    expect(content, contains('width=device-width'));
    // Flutter swaps this tag for its own once it is running, and that
    // one allows zoom (WCAG 1.4.4); this one must not forbid what that
    // one allows, or the page changes under the reader as it loads.
    expect(content, isNot(contains('user-scalable=no')), reason: 'a page nobody can zoom fails the people who need to');
    expect(content, isNot(contains('maximum-scale=1')), reason: 'nor one that can be zoomed no further than itself');
    expect(content, isNot(contains('viewport-fit=cover')),
        reason: 'Flutter web does not read the safe-area insets, so the browser keeps the page clear of the notch');
  });

  test('the page keeps the app for a load with no network, and Flutter\'s stub does not undo it', () {
    // The bootstrap is ours (docs/01-dev-loop.md, "With no network"):
    // it registers the worker that keeps the app, and it starts
    // Flutter's loader without the service worker settings that would
    // register Flutter's own — a stub that unregisters whatever is
    // registered where it is, ours included.
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
    expect(bootstrap, contains('{{flutter_js}}'));
    expect(bootstrap, contains('{{flutter_build_config}}'));
    expect(bootstrap, contains("register('offline_worker.js')"));
    expect(bootstrap, contains('_flutter.loader.load()'));
    expect(bootstrap, isNot(contains('serviceWorkerSettings')));
    expect(bootstrap, isNot(contains('{{flutter_service_worker_version}}')));
    expect(File('web/offline_worker.js').existsSync(), isTrue);
    // And the worker never keeps what has to be fresh or nothing.
    final worker = File('web/offline_worker.js').readAsStringSync();
    expect(worker, contains('/build-info.json'));
    expect(worker, contains('/api/'));
  });

  test('installed, the app turns with the device, as it does in a tab', () {
    // A phone on its side is the second composition, not a mistake
    // (docs/05-form-factors.md): an installed app locked upright would
    // be the one place it could not be had.
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync()) as Map<String, Object?>;
    expect(manifest['orientation'], anyOf(isNull, 'any'));
  });
}
