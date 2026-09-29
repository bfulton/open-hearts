/// A relay that keeps one object per tag has to be told which object
/// to open before a socket is any use, so it wears a mark in the list
/// and the client that has a tag puts it there (presence_relay.dart).
library;

import 'package:table/table.dart';
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
      // A relay with no mark is never given a path: on a public relay
      // one would be a 404, and every tag is served at the root.
      expect(relaysForTag([Uri.parse('wss://ours/fixed')], 'online'), [Uri.parse('wss://ours/fixed')]);
      expect(relaysForTag(const [], 'online'), isEmpty);
    });

    test('is where presence puts its own topic', () {
      expect(relaysForTag([Uri.parse('wss://ours/$tagMark')], RelayPresence.topic), [Uri.parse('wss://ours/online')]);
    });
  });
}
