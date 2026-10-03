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
    final relays = appRelays(base: Uri.parse('https://openhearts.game/play/'), web: true);
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
    expect(pinnedRelays(appRelays(base: Uri.parse('https://openhearts.game/play/'), web: true)), 1);
    expect(pinnedRelays(appRelays(base: Uri.parse('http://localhost:8080/'), web: true)), 0);
    expect(pinnedRelays(const []), 0);
  });

  test('presence talks to the same relay as everything else', () {
    final deployed = appRelays(base: Uri.parse('https://openhearts.game/play/'), web: true);
    expect(presenceRelays(deployed), deployed);
  });

  test('a table, a pool, the results and presence each reach the object for their own tag', () {
    final deployed = appRelays(base: Uri.parse('https://openhearts.game/play/'), web: true);
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
}
