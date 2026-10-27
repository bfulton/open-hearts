import 'dart:convert';
import 'dart:io';

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart' show FakeSigner;
import 'package:test/test.dart';

void main() {
  group('Relays', () {
    test('parses commas, spaces and newlines', () {
      expect(Relays.parse('wss://a.example, wss://b.example\n ws://c:7447 '),
          [Uri.parse('wss://a.example'), Uri.parse('wss://b.example'), Uri.parse('ws://c:7447')]);
      expect(Relays.parse(''), isEmpty);
      expect(Relays.format(Relays.parse('wss://a, wss://b')), 'wss://a, wss://b');
    });

    test('a relay\'s refusal for good: superseded, suspended or deleted, and nothing else', () {
      expect(turnedAway('superseded: another device of this account is in use'), isTrue);
      expect(turnedAway('suspended: this account is suspended from live play'), isTrue);
      expect(turnedAway('deleted: this account was deleted'), isTrue);
      expect(turnedAway('auth-required: an old answer'), isFalse, reason: 'asked again with a fresh answer');
      expect(turnedAway('rate-limited: slow down'), isFalse);
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

  group('a line to the referee', () {
    test('quiet a while, it asks for the log again; a stalled way in, unanswered, is found out and the socket made afresh', () async {
      // A relay that answers its first socket once and then nothing,
      // the socket left open: a way in that has stalled while the way
      // out carries. Every socket after it answers.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final asks = <int>[];
      server.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        final n = asks.length;
        asks.add(0);
        ws.listen((raw) {
          final m = jsonDecode(raw as String) as List;
          if (m[0] != 'LOG') return;
          asks[n]++;
          if (n == 0 && asks[n] > 1) return;
          ws.add(jsonEncode(['LOGEND', m[1], 0]));
        });
      });
      final line = RelayLine(
          relays: [Uri.parse('ws://127.0.0.1:${server.port}')], signer: FakeSigner('quiet'), table: 'ab' * 16, cutOffMs: 1200);
      addTearDown(line.close);
      final ups = <bool>[];
      line.onUp = ups.add;
      line.open(0, (_) {});
      final until = DateTime.now().add(const Duration(seconds: 10));
      while (ups.length < 3 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(asks.first, greaterThanOrEqualTo(2), reason: 'asked again once quiet, with nothing else to say');
      expect(asks, hasLength(2), reason: 'its ask unanswered, the line made its socket afresh');
      expect(ups, [true, false, true], reason: 'up, down for the stall, and up again on the new socket');
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
