/// Presence said again (docs/security-review.md): every presence
/// event is public, and any relay takes one again once it has forgotten
/// its id. An old `here` must not make a device that left look online,
/// nor an old `gone` take a present one out.
library;

import 'dart:convert';

import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  final me = FakeSigner('01');
  final them = FakeSigner('02');
  final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Map<String, Object?> said(String kind, int at) => NostrEvent.sign(them,
          kind: TableKinds.presence, content: jsonEncode({'kind': kind, 'status': 'online'}), tags: [['t', RelayPresence.topic]], createdAt: at)
      .toJson();

  late RelayPresence presence;
  setUp(() => presence = RelayPresence(relays: [Uri.parse('ws://127.0.0.1:9')], signer: me));
  tearDown(() => presence.close());

  bool online() => presence.online(withinMs: 15000).contains(them.publicKey);

  test('a here from now is someone here', () {
    presence.receive(said('here', nowS));
    expect(online(), isTrue);
  });

  test('an old here, said again, is nobody', () {
    presence.receive(said('here', nowS - 600));
    expect(online(), isFalse);
  });

  test('a gone older than the here after it does not take them out', () {
    presence.receive(said('here', nowS));
    presence.receive(said('gone', nowS - 5));
    expect(online(), isTrue, reason: 'a replayed gone from before the here');
    presence.receive(said('gone', nowS + 1));
    expect(online(), isFalse, reason: 'a gone said after it is news');
  });

  test('a here dated in the future is nobody', () {
    presence.receive(said('here', nowS + 3600));
    expect(online(), isFalse);
  });
}
