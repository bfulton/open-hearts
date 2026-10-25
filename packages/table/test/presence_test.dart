/// A relay that keeps one object per tag has to be told which object
/// to open before a socket is any use, so it wears a mark in the list
/// and the client that has a tag puts it there (presence_relay.dart).
/// And who presence counts as people.
library;

import 'dart:convert';

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  group('a relay marked as one object per tag', () {
    test('takes the tag in its path, and every other relay is left as it was', () {
      final relays = Relays.parse('wss://ours/$tagMark, wss://relay.damus.io, ws://127.0.0.1:7447');
      expect(relaysForTag(relays, 'online'), [
        Uri.parse('wss://ours/online'),
        Uri.parse('wss://relay.damus.io'),
        Uri.parse('ws://127.0.0.1:7447'),
      ]);
      // The mark is a whole path segment, wherever it sits.
      expect(relaysForTag([Uri.parse('wss://ours/relay/$tagMark')], 'T1'), [Uri.parse('wss://ours/relay/T1')]);
      // A relay with no mark is never given a path: on a relay that
      // serves every tag at the root, one would be a 404.
      expect(relaysForTag([Uri.parse('wss://ours/fixed')], 'online'), [Uri.parse('wss://ours/fixed')]);
      expect(relaysForTag(const [], 'online'), isEmpty);
    });

    test('is where presence puts its own topic', () {
      expect(relaysForTag([Uri.parse('wss://ours/$tagMark')], RelayPresence.topic), [Uri.parse('wss://ours/online')]);
    });
  });

  group('the people online', () {
    final me = FakeSigner('01');
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    Map<String, Object?> here(Signer who, String status, {int after = 0}) => NostrEvent.sign(who,
            kind: TableKinds.presence,
            content: jsonEncode({'kind': 'here', 'status': status}),
            tags: [['t', RelayPresence.topic]],
            createdAt: nowS + after)
        .toJson();

    late RelayPresence presence;
    setUp(() => presence = RelayPresence(relays: [Uri.parse('ws://127.0.0.1:9')], signer: me));
    tearDown(() => presence.close());

    test('leave out a backup juror, who is still there for a jury', () {
      final them = FakeSigner('02');
      final bench = FakeSigner('03');
      presence.receive(here(bench, RelayPresence.lastResort));
      presence.receive(here(them, 'online'));
      expect(presence.online(withinMs: 15000), {me.publicKey, them.publicKey, bench.publicKey});
      expect(presence.people(withinMs: 15000), {me.publicKey, them.publicKey});

      // Somebody at a table is somebody.
      presence.receive(here(them, RelayPresence.seated, after: 1));
      expect(presence.people(withinMs: 15000), {me.publicKey, them.publicKey});
    });

    test('count this device while it says it is here, not by its own beat heard back', () {
      var able = true;
      final mine = RelayPresence(relays: [Uri.parse('ws://127.0.0.1:9')], signer: me, canServe: () => able);
      addTearDown(mine.close);
      // A relay sends a device its own beat, as it sends everyone's; the
      // one it said before it could no longer serve stays a minute fresh.
      mine.receive(here(me, 'online'));
      expect(mine.online(withinMs: 15000), {me.publicKey});
      able = false;
      expect(mine.online(withinMs: 15000), isEmpty, reason: 'a device that cannot serve is not here, whatever it heard of itself');
      able = true;
      mine.silent = true;
      expect(mine.online(withinMs: 15000), isEmpty, reason: 'nor while it is silent');
    });
  });
}
