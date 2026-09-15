/// Where a build looks for its relays: decided by the build and where
/// it is served from, never typed in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/relays.dart';
import 'package:table/table.dart';

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

  test('presence puts our per-tag object in front of a deployed list, and nothing in front of a local one', () {
    final deployed = appRelays(base: Uri.parse('https://open-hearts.pages.dev/play/'));
    final presence = presenceRelays(deployed);
    // Uri writes the mark's braces out as escapes; it is the path
    // segment that carries it, which is how it is read back.
    expect(presence.first, Uri.parse(homeTagRelay));
    expect(presence.sublist(1), deployed, reason: 'the relays are still there, and still the fallback');
    // The mark is what tells a client to put the tag in the path, and
    // it is ours alone: a public relay serves every tag at its root.
    expect(presence.first.pathSegments, contains(tagMark));
    expect(presence.sublist(1).any((r) => r.pathSegments.contains(tagMark)), isFalse);
    // A local build and the rig have no object of ours to reach.
    final local = appRelays(base: Uri.parse('http://localhost:8080/'));
    expect(presenceRelays(local), local);
    // And what a table is written to never carries it: a table has
    // nowhere to put a tag, and has not moved to the object.
    expect(deployed.any((r) => r.pathSegments.contains(tagMark)), isFalse);
  });

  test('served from localhost, the local relay', () {
    expect(appRelays(base: Uri.parse('http://localhost:8080/')).map((r) => r.toString()), [localRelay]);
    expect(appRelays(base: Uri.parse('http://127.0.0.1:41234/?e2e=1')).map((r) => r.toString()), [localRelay]);
  });
}
