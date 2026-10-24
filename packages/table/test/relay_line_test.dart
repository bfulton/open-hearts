/// A relay connection that hears nothing back takes itself for cut off
/// (relays.dart, RelayConnection.cutOff), and makes its socket afresh —
/// over a real socket to a relay that answers everything, as ours does,
/// until it is told to go silent with the socket left open: the way in
/// stalled, as a satellite link on a plane stalled it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// A relay of the fewest words: the end of what it holds for every
/// subscription, OK for every event. [silent] says nothing at all, to
/// any socket, without closing one.
class _Relay {
  late final HttpServer _server;
  final sockets = <WebSocket>[];
  var silent = false;
  var events = 0;

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.transform(WebSocketTransformer()).listen((ws) {
      sockets.add(ws);
      ws.listen((raw) {
        final m = jsonDecode(raw as String) as List<Object?>;
        if (m[0] == 'EVENT') events++;
        if (silent) return;
        if (m[0] == 'REQ') ws.add(jsonEncode(['EOSE', m[1]]));
        if (m[0] == 'EVENT') ws.add(jsonEncode(['OK', (m[1] as Map)['id'], true, '']));
      }, onError: (_) {});
    });
  }

  Future<void> stop() async {
    for (final s in sockets) {
      await s.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  late _Relay relay;
  setUp(() async {
    relay = _Relay();
    await relay.start();
  });
  tearDown(() => relay.stop());

  // A tenth of the real thing: a second of nothing with an event a
  // tenth of a second unanswered.
  const cutOffMs = 1000, answerWaitMs = 300;

  final signer = FakeSigner('line');
  NostrEvent event() => NostrEvent.sign(signer, kind: TableKinds.table, content: '{}', tags: const []);

  RelayConnection connect() {
    final c = RelayConnection(
        url: relay.url,
        subscriptions: {
          's': [const Filter(kinds: [TableKinds.table]).toJson()]
        },
        onMessage: (_, __) {},
        cutOffMs: cutOffMs,
        answerWaitMs: answerWaitMs);
    addTearDown(c.close);
    return c;
  }

  Future<void> sending(RelayConnection c, Duration over) async {
    final until = DateTime.now().add(over);
    while (DateTime.now().isBefore(until)) {
      c.publish(event());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.cutOff, isFalse, reason: 'answered all along');
    }
  }

  test('a relay that answers: never cut off, sending or not', () async {
    final c = connect();
    await c.ready.timeout(const Duration(seconds: 5));
    expect(c.cutOff, isFalse);
    await sending(c, const Duration(milliseconds: cutOffMs * 2));
    // Quiet with nothing sent is a quiet table, not a line down.
    await Future<void>.delayed(const Duration(milliseconds: cutOffMs * 2));
    expect(c.cutOff, isFalse, reason: 'nothing sent, nothing owed');
    // And the first word after a long quiet is owed its answer's time.
    c.publish(event());
    expect(c.cutOff, isFalse, reason: 'the relay quiet only because nothing was said');
    await Future<void>.delayed(const Duration(milliseconds: answerWaitMs * 2));
    expect(c.cutOff, isFalse);
    expect(c.silences, 0);
    expect(c.drops, 0);
  });

  test('a relay gone silent with the socket open: cut off, and the socket made afresh', () async {
    final c = connect();
    await c.ready.timeout(const Duration(seconds: 5));
    relay.silent = true;
    final went = DateTime.now();
    final sent = relay.events;
    while (!c.cutOff) {
      c.publish(event());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(DateTime.now().difference(went).inMilliseconds, lessThan(cutOffMs * 3), reason: 'found out in time');
    }
    expect(DateTime.now().difference(went).inMilliseconds, greaterThanOrEqualTo(cutOffMs), reason: 'and not before');
    expect(relay.events, greaterThan(sent), reason: 'the way out carried all along');
    expect(c.drops, c.silences, reason: 'the socket never closed of itself, only for its silence');
    // The liveness check makes it afresh; the relay answers that one.
    relay.silent = false;
    final remade = DateTime.now().add(const Duration(milliseconds: cutOffMs * 2));
    while (c.silences == 0 && DateTime.now().isBefore(remade)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(c.silences, 1, reason: 'dropped for its silence');
    expect(c.drops, 1);
    final back = DateTime.now().add(const Duration(seconds: 5));
    while (!c.connected && DateTime.now().isBefore(back)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(relay.sockets, hasLength(2), reason: 'on a new socket');
    await sending(c, const Duration(milliseconds: cutOffMs * 2));
    expect(c.silences, 1);
  });

  test('a group is cut off only when every relay is', () async {
    final other = _Relay();
    await other.start();
    addTearDown(other.stop);
    final g = RelayGroup(
        urls: [relay.url, other.url],
        subscriptions: {
          's': [const Filter(kinds: [TableKinds.table]).toJson()]
        },
        onEvent: (_) => true,
        cutOffMs: cutOffMs,
        answerWaitMs: answerWaitMs);
    addTearDown(g.close);
    await g.allReady.timeout(const Duration(seconds: 5));
    relay.silent = true;
    Future<void> sendFor(Duration d) async {
      final until = DateTime.now().add(d);
      while (DateTime.now().isBefore(until)) {
        g.publish(event(), everywhere: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await sendFor(const Duration(milliseconds: cutOffMs * 3 ~/ 2));
    expect(g.connections.where((c) => c.cutOff), hasLength(lessThanOrEqualTo(1)));
    expect(g.cutOff, isFalse, reason: 'one relay still answering: ${g.health}');
    expect(g.health, isNot(contains('cut off')));
    other.silent = true;
    // Every relay silent; the first is made afresh into a relay still
    // silent, and stays cut off.
    final until = DateTime.now().add(const Duration(milliseconds: cutOffMs * 6));
    while (!g.cutOff && DateTime.now().isBefore(until)) {
      g.publish(event(), everywhere: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final health = g.health;
    expect(health, contains('cut off'));
    expect(health, matches(RegExp(r'for silence [1-9]')), reason: 'made afresh for it');
  });
}
