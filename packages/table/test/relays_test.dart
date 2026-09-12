import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  group('Relays', () {
    test('parses commas, spaces and newlines', () {
      expect(Relays.parse('wss://a.example, wss://b.example\n ws://c:7447 '),
          [Uri.parse('wss://a.example'), Uri.parse('wss://b.example'), Uri.parse('ws://c:7447')]);
      expect(Relays.parse(''), isEmpty);
      expect(Relays.format(Relays.parse('wss://a, wss://b')), 'wss://a, wss://b');
    });

    test('turns the list by a key: a rotation, the same every time', () {
      final relays = [for (var i = 0; i < 5; i++) Uri.parse('wss://r$i')];
      final seen = <Uri>{};
      for (var t = 0; t < 40; t++) {
        final turned = Relays.turnedBy(relays, 'table-$t');
        expect(turned, hasLength(5));
        expect(turned.toSet(), relays.toSet());
        // A rotation keeps the order going round.
        final k = relays.indexOf(turned.first);
        expect(turned, [...relays.sublist(k), ...relays.sublist(0, k)]);
        expect(Relays.turnedBy(relays, 'table-$t'), turned);
        seen.add(turned.first);
      }
      // Forty tables begin on more than one relay.
      expect(seen.length, greaterThan(2));
      expect(Relays.turnedBy([relays.first], 'x'), [relays.first]);
      expect(Relays.turnedBy(const [], 'x'), isEmpty);
    });

    test('a known key lands where it did: the hash is not the platform\'s', () {
      final relays = [for (var i = 0; i < 7; i++) Uri.parse('wss://r$i')];
      // FNV-1a of 'HRTS' mod 7, pinned.
      expect(Relays.turnedBy(relays, 'HRTS').first, Uri.parse('wss://r${_fnv('HRTS') % 7}'));
    });
  });
}

int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final u in s.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xffffffff;
  }
  return h;
}
