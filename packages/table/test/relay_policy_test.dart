/// The shared write-selection policy, pinned: the rules relays.dart and
/// the simulator both lean on, so a change to either meets these first.
library;

import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  group('turnedBy', () {
    final r = [Uri.parse('wss://a'), Uri.parse('wss://b'), Uri.parse('wss://c'), Uri.parse('wss://d')];
    test('rotates the whole list by the key', () {
      for (final key in ['t1', 't2', 'zzz']) {
        final turned = Relays.turnedBy(r, key);
        expect(turned.toSet(), r.toSet(), reason: 'the same relays, reordered');
        // A rotation: some entry begins it, the rest follow in order.
        final start = r.indexOf(turned.first);
        expect(turned, [...r.sublist(start), ...r.sublist(0, start)]);
      }
    });
    test('a pinned front stays first while the rest rotate', () {
      for (final key in ['t1', 't2', 'across', 'zzz', 'mumtaz']) {
        final turned = Relays.turnedBy(r, key, pinned: 1);
        expect(turned.first, r.first, reason: 'the pinned relay is always primary');
        expect(turned.toSet(), r.toSet());
        final tail = turned.sublist(1);
        final start = r.sublist(1).indexOf(tail.first);
        expect(tail, [...r.sublist(1).sublist(start), ...r.sublist(1).sublist(0, start)]);
      }
    });
    test('too few to rotate is returned as is', () {
      expect(Relays.turnedBy([r.first], 'k'), [r.first]);
      expect(Relays.turnedBy([r[0], r[1]], 'k', pinned: 1), [r[0], r[1]]);
    });
  });

  group('floodWrite', () {
    test('everywhere always floods', () {
      expect(floodWrite(['a', 'b'], null, everywhere: true), isTrue);
      expect(floodWrite(['a', 'b'], {'a'}, everywhere: true), isTrue);
      expect(floodWrite(<String>[], null, everywhere: true), isTrue);
    });
    test('no readBy is a single write', () {
      expect(floodWrite(['a', 'b'], null, everywhere: false), isFalse);
    });
    test('a readable relay up is a single write', () {
      expect(floodWrite(['a', 'b'], {'b'}, everywhere: false), isFalse);
    });
    test('no readable relay up floods, so the event reaches a relay someone can read', () {
      expect(floodWrite(['a', 'b'], {'c'}, everywhere: false), isTrue);
    });
    test('nothing up is not a flood — there is nowhere to flood to', () {
      expect(floodWrite(<String>[], {'a'}, everywhere: false), isFalse);
    });
  });

  group('firstTarget', () {
    test('the first in order that is up', () {
      expect(firstTarget(['a', 'b', 'c'], {'b', 'c'}, null), 'b');
    });
    test('the first in order that is up and read', () {
      expect(firstTarget(['a', 'b', 'c'], {'a', 'b', 'c'}, {'b', 'c'}), 'b');
    });
    test('none up and read', () {
      expect(firstTarget(['a', 'b'], {'a'}, {'b'}), isNull);
      expect(firstTarget(['a', 'b'], <String>{}, null), isNull);
    });
  });

  group('readByFrom', () {
    test('the intersection of what peers read', () {
      final reads = {
        'p1': (reads: {'a', 'b'}, at: 1000),
        'p2': (reads: {'b', 'c'}, at: 1000),
      };
      expect(readByFrom(reads, 1000, 120000), {'b'});
    });
    test('null when nobody has said', () {
      expect(readByFrom(<String, ({Set<String> reads, int at})>{}, 1000, 120000), isNull);
    });
    test('a peer long unheard is dropped, and the map pruned', () {
      final reads = {
        'p1': (reads: {'a', 'b'}, at: 0),
        'p2': (reads: {'b', 'c'}, at: 200000),
      };
      expect(readByFrom(reads, 200000, 120000), {'b', 'c'});
      expect(reads.keys, ['p2']);
    });
  });
}
