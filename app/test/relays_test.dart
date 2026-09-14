/// Where a build looks for its relays: decided by the build and where
/// it is served from, never typed in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/relays.dart';

void main() {
  test('a deployed build starts on our own relay first, then the public ones', () {
    final relays = appRelays(base: Uri.parse('https://open-hearts.pages.dev/play/'));
    expect(relays.map((r) => r.toString()), publicRelays);
    expect(relays.first.toString(), homeRelay, reason: 'our own relay leads the list');
    expect(relays.length, greaterThanOrEqualTo(3), reason: 'one relay turning is not the end of a table');
    for (final r in relays) {
      expect(r.scheme, 'wss');
      expect(r.host, isNotEmpty);
    }
  });

  test('the home relay is pinned primary in a deployed list, and nowhere else', () {
    expect(pinnedRelays(appRelays(base: Uri.parse('https://open-hearts.pages.dev/play/'))), 1);
    expect(pinnedRelays(appRelays(base: Uri.parse('http://localhost:8080/'))), 0);
    expect(pinnedRelays(const []), 0);
  });

  test('served from localhost, the local relay', () {
    expect(appRelays(base: Uri.parse('http://localhost:8080/')).map((r) => r.toString()), [localRelay]);
    expect(appRelays(base: Uri.parse('http://127.0.0.1:41234/?e2e=1')).map((r) => r.toString()), [localRelay]);
  });
}
