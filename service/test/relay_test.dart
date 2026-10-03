import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A test client: sends arrays, collects what comes back.
class Client {
  Client(Uri url) : channel = WebSocketChannel.connect(url) {
    channel.stream.listen((raw) {
      final m = jsonDecode(raw as String) as List;
      received.add(m);
      for (final w in List.of(_waiting)) {
        if (w.$1(m)) {
          _waiting.remove(w);
          w.$2.complete(m);
        }
      }
    });
  }

  final WebSocketChannel channel;
  final List<List> received = [];
  final List<(bool Function(List), Completer<List>)> _waiting = [];

  Future<void> get ready => channel.ready;

  void send(List<Object?> m) => channel.sink.add(jsonEncode(m));

  /// The next message satisfying [where], already received or to come.
  Future<List> next(bool Function(List m) where) {
    for (final m in received) {
      if (where(m)) return Future.value(m);
    }
    final c = Completer<List>();
    _waiting.add((where, c));
    return c.future.timeout(const Duration(seconds: 5));
  }

  Future<void> close() => channel.sink.close();
}

void main() {
  // The relay at a bare address, every kind stored, any tag on one
  // socket: the Dart relay and the JS core as the local rig runs them.
  // The deployed object (`OH_RELAY=object`) is one tag an address and
  // stores only its own lobby; its rules are tested in service/do
  // (relay.test.mjs, tag_store.test.mjs), and the table suites here
  // run over it.
  if (Platform.environment['OH_RELAY'] == 'object') {
    test('the general relay', () {}, skip: 'the deployed object has its own rules, tested in service/do');
    return;
  }
  late Relay relay;
  setUp(() async {
    relay = Relay();
    await relay.serve();
  });
  tearDown(() => relay.close());

  test('a valid event is accepted and reaches every matching subscriber; an invalid one is refused', () async {
    final a = Client(relay.url);
    final b = Client(relay.url);
    await a.ready;
    await b.ready;
    b.send(['REQ', 'tables', {'kinds': [TableKinds.table], '#t': ['T1']}]);
    await b.next((m) => m[0] == 'EOSE' && m[1] == 'tables');

    final signer = SchnorrSigner.generate();
    final e = NostrEvent.sign(signer, kind: TableKinds.table, content: '{"x":1}', tags: [['t', 'T1']]);
    a.send(['EVENT', e.toJson()]);
    final ok = await a.next((m) => m[0] == 'OK' && m[1] == e.id);
    expect(ok[2], isTrue);
    final got = await b.next((m) => m[0] == 'EVENT' && m[1] == 'tables');
    expect((got[2] as Map)['id'], e.id);

    // Another table: b does not hear it.
    final other = NostrEvent.sign(signer, kind: TableKinds.table, content: '{}', tags: [['t', 'T2']]);
    a.send(['EVENT', other.toJson()]);
    await a.next((m) => m[0] == 'OK' && m[1] == other.id);

    // Forged: refused, and nobody hears it.
    final forged = Map<String, Object?>.from(e.toJson())..['content'] = '{"x":2}';
    a.send(['EVENT', forged]);
    final refused = await a.next((m) => m[0] == 'OK' && m[2] == false);
    expect(refused[3], contains('invalid'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(b.received.where((m) => m[0] == 'EVENT').length, 1);

    // The relay's own count: ephemeral kinds are not stored.
    expect(relay.stored, 0);
    await a.close();
    await b.close();
  });

  test('stored kinds are replayed to a late subscriber, newest last, with since and limit honoured', () async {
    final a = Client(relay.url);
    await a.ready;
    final signer = SchnorrSigner.generate();
    final events = [
      for (var i = 0; i < 5; i++) NostrEvent.sign(signer, kind: 1, content: 'n$i', createdAt: 1000 + i),
    ];
    for (final e in events) {
      a.send(['EVENT', e.toJson()]);
      await a.next((m) => m[0] == 'OK' && m[1] == e.id);
    }
    expect(relay.stored, 5);

    final late = Client(relay.url);
    await late.ready;
    late.send(['REQ', 's', {'kinds': [1], 'since': 1002}]);
    await late.next((m) => m[0] == 'EOSE');
    expect(late.received.where((m) => m[0] == 'EVENT').map((m) => (m[2] as Map)['content']), ['n2', 'n3', 'n4']);

    late.send(['REQ', 'l', {'kinds': [1], 'limit': 2}]);
    await late.next((m) => m[0] == 'EOSE' && m[1] == 'l');
    expect(late.received.where((m) => m[0] == 'EVENT' && m[1] == 'l').map((m) => (m[2] as Map)['content']), ['n3', 'n4']);

    // A duplicate is acknowledged and not stored twice.
    a.send(['EVENT', events[0].toJson()]);
    final dup = await a.next((m) => m[0] == 'OK' && m[1] == events[0].id && (m[3] as String).contains('duplicate'));
    expect(dup[2], isTrue);
    expect(relay.stored, 5);

    // CLOSE stops the stream.
    late.send(['CLOSE', 's']);
    late.send(['CLOSE', 'l']);
    final more = NostrEvent.sign(signer, kind: 1, content: 'n5', createdAt: 1005);
    a.send(['EVENT', more.toJson()]);
    await a.next((m) => m[0] == 'OK' && m[1] == more.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(late.received.any((m) => m[0] == 'EVENT' && (m[2] as Map)['content'] == 'n5'), isFalse);
    await a.close();
    await late.close();
  });

  test('nonsense gets a notice, not a dropped connection', () async {
    final a = Client(relay.url);
    await a.ready;
    a.channel.sink.add('not json');
    final n = await a.next((m) => m[0] == 'NOTICE');
    expect(n[1], 'not JSON');
    a.send(['HELLO']);
    await a.next((m) => m[0] == 'NOTICE' && (m[1] as String).contains('unknown'));
    a.send(['REQ', 'x', {'kinds': 'no'}]);
    await a.next((m) => m[0] == 'NOTICE' && m[1] == 'bad filter');
    expect(relay.connections, 1);
    await a.close();
  });
}
