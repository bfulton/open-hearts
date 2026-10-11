/// Where a build looks for its relays: decided by the build and where
/// it is served from, never typed in — and ours alone
/// (docs/08-own-relays.md).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/duty.dart';
import 'package:open_hearts/net/relays.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:table/table.dart';

void main() {
  test('a deployed build talks to our relay and nobody else', () {
    final relays = appRelays(base: Uri.parse('https://play.openhearts.game/'), web: true);
    expect(relays, [Uri.parse(ourRelay)]);
    for (final r in relays) {
      expect(r.scheme, 'wss');
      expect(RemoteConfig.ours(r), isTrue);
      expect(r.pathSegments, contains(tagMark), reason: 'one object per tag: the tag goes in the address');
    }
  });

  test('a phone build is a deployed build, not a local one', () {
    // A phone's app has no address it was served from.
    expect(appRelays(base: Uri.parse('file:///'), web: false), [Uri.parse(ourRelay)]);
    expect(appRelays(base: Uri(), web: false), [Uri.parse(ourRelay)]);
  });

  test('ours are pinned first, a local relay is not', () {
    expect(pinnedRelays(appRelays(base: Uri.parse('https://play.openhearts.game/'), web: true)), 1);
    expect(pinnedRelays(appRelays(base: Uri.parse('http://localhost:8080/'), web: true)), 0);
    // The browser rig's stand-in for play.openhearts.game is this machine.
    expect(appRelays(base: Uri.parse('http://play.openhearts.localhost:8080/'), web: true), [Uri.parse(localRelay)]);
    expect(pinnedRelays(const []), 0);
  });

  test('a table, a pool, the results and presence each reach the object for their own tag', () {
    final deployed = appRelays(base: Uri.parse('https://play.openhearts.game/'), web: true);
    for (final tag in ['mf66d4537', 'queue:anyone', 'results', 'KP4T9MXR']) {
      final t = RelayTransport(relays: deployed, signer: FakeSigner('t'), table: tag, pinned: pinnedRelays(deployed));
      addTearDown(t.close);
      expect(t.relays.single.host, 'relay.openhearts.game');
      expect(t.relays.single.pathSegments.single, tag, reason: 'the tag written in, not the mark');
    }
    final duty = Duty.on(deployed, FakeSigner('door'));
    addTearDown(duty.close);
    expect(duty.presence.relays.single.pathSegments.single, 'online');
  });

  test('served from localhost, the local relay', () {
    expect(appRelays(base: Uri.parse('http://localhost:8080/'), web: true).map((r) => r.toString()), [localRelay]);
    expect(appRelays(base: Uri.parse('http://127.0.0.1:41234/?e2e=1'), web: true).map((r) => r.toString()), [localRelay]);
  });

  test('served from localhost, the local relay at the port the address names', () {
    // Each browser suite's relay is on a port of its own (e2e/drive.mjs).
    expect(appRelays(base: Uri.parse('http://play.openhearts.localhost:41234/room/AB12?e2e=1&relay=40123'), web: true),
        [Uri.parse('ws://127.0.0.1:40123')]);
    // A port and nothing else: anything more is no port, and the usual one.
    for (final nonsense in ['0', '70000', 'evil.example', 'ws://evil.example:1', '']) {
      expect(appRelays(base: Uri.parse('http://localhost:8080/?relay=${Uri.encodeComponent(nonsense)}'), web: true),
          [Uri.parse(localRelay)], reason: nonsense);
    }
    // And never read where the build is deployed.
    expect(appRelays(base: Uri.parse('https://play.openhearts.game/?e2e=1&relay=40123'), web: true), [Uri.parse(ourRelay)]);
  });
}
