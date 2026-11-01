/// The house as it runs (service/bin/house.dart): a process of its own,
/// woken on its port for a table or a pool that wants it — as the
/// Cloudflare Container is, by the tag's object (service/do/bench.mjs) —
/// and following the table from its log, or seating the pool, on real
/// sockets, with real keys.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deal/memo.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// BIP-340's third published pair: the house of these tests, as of the
/// browser rig's (packages/table, tool/game_fixture.dart).
const _houseSecret = 'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9';
const _house = 'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8';

Future<void> until(String what, FutureOr<bool> Function() holds, {Duration within = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(within);
  while (!await holds()) {
    if (DateTime.now().isAfter(deadline)) fail(what);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// A free port: taken, then given back.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// The house process, its lines kept for a failure to show.
class HouseProcess {
  HouseProcess._(this.process, this.port);

  static Future<HouseProcess> start(Relay relay, {Map<String, String> env = const {}}) async {
    final port = await freePort();
    final p = await Process.start(Platform.resolvedExecutable, ['run', 'bin/house.dart', '--relay', '${relay.url}', '--port', '$port'],
        environment: {'OH_HOUSE_SECRET': _houseSecret, ...env});
    final h = HouseProcess._(p, port);
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(h.said.add);
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(h.said.add);
    return h;
  }

  final Process process;
  final int port;
  final List<String> said = [];

  Uri at(String path, [Map<String, String>? query]) => Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: query);

  Future<(int, String)> ask(String method, String path, [Map<String, String>? query, Object? body]) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, at(path, query));
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }

  Future<bool> up() async {
    try {
      return (await ask('GET', '/ping')).$1 == 200;
    } on SocketException {
      return false;
    }
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
  }
}

void main() {
  setUpAll(() => installNativeSchnorr());

  test('woken for a sealed table, the house deals and plays its bots, and says how the game came out, there and in the results',
      () async {
    final crypto = await rememberedCrypto(kept: false);
    late HouseProcess house;
    final wanted = <String>[];
    final relay = Relay(
      house: _house,
      // What the table's object does: the house woken on its port.
      onWanted: (table) {
        wanted.add(table);
        unawaited(house.ask('POST', '/wake', {'table': table}).then((_) {}, onError: (_) {}));
      },
    );
    await relay.serve();
    addTearDown(relay.close);
    house = await HouseProcess.start(relay, env: {'OH_HOUSE_KEY': _house});
    addTearDown(house.stop);
    await until('the house did not come up: ${house.said}', house.up, within: const Duration(seconds: 60));
    expect(jsonDecode((await house.ask('GET', '/status')).$2), {'online': false, 'serving': 0}, reason: 'asleep until a table wants it');
    expect((await house.ask('POST', '/wake', {'table': 'not a table'})).$1, 400);

    final people = [SchnorrSigner.generate(), SchnorrSigner.generate()];
    final spec = TableSpec(salt: newSalt(), seed: 21, target: 1, sealed: true, house: _house, seats: [
      HumanSeat(people[0].publicKey),
      const BotSeat(Persona.romeo),
      const BotSeat(Persona.juliet),
      HumanSeat(people[1].publicKey),
    ]);
    final clock = WallClock();
    final clients = [
      for (final p in people)
        TableClient(
            tableId: spec.id, spec: spec, signer: p, line: RelayLine(relays: [relay.url], signer: p, table: spec.id), clock: clock, crypto: crypto),
    ];
    for (final c in clients) {
      c.start();
    }
    final players = [for (final c in clients) Player(c)];
    addTearDown(() {
      for (final p in players) {
        p.stop();
      }
      for (final c in clients) {
        c.close();
      }
    });
    await until('the house was not serving the table: ${house.said.join('\n')}',
        () async => jsonDecode((await house.ask('GET', '/status')).$2)['serving'] == 1);
    await until('the game did not end: ${clients.map((c) => c.rules.describe()).join(' / ')}\n${house.said.join('\n')}',
        () => clients.every((c) => c.done && c.rules.result != null), within: const Duration(minutes: 3));
    expect(wanted.first, spec.id);
    final rules = clients.first.rules;
    expect(rules.state, TableState.finished);
    expect(rules.result!.author, _house);

    // The house's word on it is on the results tag too: the one the
    // ratings take, and the game's own.
    NostrEvent? said;
    await until('the house published no result: ${house.said.join('\n')}', () async {
      said = await storedResult(relay, spec.id);
      return said != null;
    }, within: const Duration(seconds: 20));
    expect(said!.pubkey, _house);
    expect(GameResult.parse(said!)!.toJson(), GameResult.ofTable(rules)!.toJson());
    // Done with the table, and online a while yet for the next.
    await until('the house still serves a table that is over', () async => jsonDecode((await house.ask('GET', '/status')).$2)['serving'] == 0,
        within: const Duration(seconds: 10));
    expect(jsonDecode((await house.ask('GET', '/status')).$2)['online'], isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('woken for a table it will not serve, the house says so in the table\'s log, the table ends, and it is not woken for it again; nothing is rated', () async {
    final crypto = await rememberedCrypto(kept: false);
    late HouseProcess house;
    final wanted = <String>[];
    final relay = Relay(
      house: _house,
      // What the table's object does: the house woken on its port.
      onWanted: (table) {
        wanted.add(table);
        unawaited(house.ask('POST', '/wake', {'table': table}).then((_) {}, onError: (_) {}));
      },
    );
    await relay.serve();
    addTearDown(relay.close);
    house = await HouseProcess.start(relay, env: {'OH_HOUSE_KEY': _house});
    addTearDown(house.stop);
    await until('the house did not come up: ${house.said}', house.up, within: const Duration(seconds: 60));

    // Any one of a table's people writes its start: this one says it is
    // rated, with a salt that is not the house's.
    final people = [SchnorrSigner.generate(), SchnorrSigner.generate()];
    final spec = TableSpec(salt: newSalt(), seed: 22, target: 1, rated: true, sealed: true, house: _house, seats: [
      HumanSeat(people[0].publicKey),
      const BotSeat(Persona.romeo),
      const BotSeat(Persona.juliet),
      HumanSeat(people[1].publicKey),
    ]);
    final clock = WallClock();
    final clients = [
      for (final p in people)
        TableClient(
            tableId: spec.id, spec: spec, signer: p, line: RelayLine(relays: [relay.url], signer: p, table: spec.id), clock: clock, crypto: crypto),
    ];
    for (final c in clients) {
      c.start();
    }
    addTearDown(() {
      for (final c in clients) {
        c.close();
      }
    });
    // Over at the house's word, not at a turn of its running out, which
    // takes a minute.
    await until('the table did not end at the house\'s word', () => clients.every((c) => c.done), within: const Duration(seconds: 30));
    for (final c in clients) {
      expect(c.state, TableState.failed);
      expect(c.rules.result!.author, _house);
      expect(c.rules.result!.body, c.rules.refusal);
    }
    expect(house.said.join('\n'), contains('a rated table the house did not seat; not served'));
    await until('the house still serves the table', () async => jsonDecode((await house.ask('GET', '/status')).$2)['serving'] == 0, within: const Duration(seconds: 10));

    // The table's object asks for the house at most once in twenty
    // seconds until it has said a result: it has.
    await Future<void>.delayed(const Duration(seconds: 25));
    expect(wanted, [spec.id], reason: 'woken as the table started, and not again');
    expect(await storedResult(relay, spec.id), isNull, reason: 'nothing for the ratings');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('woken for a pool, the house seats it, by the clocks the wake says', () async {
    late HouseProcess house;
    final wanted = <String>[];
    // The operator's clocks, as the bench says them with every wake.
    final clocks = TableTiming.parse({'graceMs': 4000});
    final relay = Relay(
      house: _house,
      // What the pool's object does: the house woken on its port.
      onWanted: (tag) {
        wanted.add(tag);
        final what = tag.startsWith(RelayTransport.poolPrefix) ? 'pool' : 'table';
        unawaited(house.ask('POST', '/wake', {what: tag}, {'timing': clocks.toJson()}).then((_) {}, onError: (_) {}));
      },
    );
    await relay.serve();
    addTearDown(relay.close);
    house = await HouseProcess.start(relay, env: {'OH_HOUSE_KEY': _house});
    addTearDown(house.stop);
    await until('the house did not come up: ${house.said}', house.up, within: const Duration(seconds: 60));
    for (final tag in ['queue:ranked', 'queue:unrated:50', 'queue:unrated:0', 'ROOM42']) {
      expect((await house.ask('POST', '/wake', {'pool': tag})).$1, 400, reason: '$tag is no pool');
    }
    expect(jsonDecode((await house.ask('GET', '/status')).$2)['serving'], 0, reason: 'nothing woken for that');

    final me = SchnorrSigner.generate();
    final t = RelayTransport(relays: [relay.url], signer: me, table: poolTag('unrated'));
    await t.ready;
    final room = WaitingRoom(relay: t, pool: 'unrated', name: 'Ada', rating: 1500, house: _house);
    addTearDown(() {
      room.close();
      t.close();
    });
    final seated = room.seated.first;
    room.playWithBots();
    final spec = await seated.timeout(const Duration(seconds: 60), onTimeout: () => fail('not seated: ${house.said.join('\n')}'));
    expect(wanted.first, poolTag('unrated'), reason: 'the pool woke the house');
    expect(spec.house, _house);
    expect(spec.sealed, isTrue);
    expect(spec.timing, clocks, reason: 'the clocks the wake said, not the standard table\'s');
    expect(spec.seats.whereType<HumanSeat>().map((h) => h.key), [me.publicKey]);
    expect(spec.seats.whereType<BotSeat>(), hasLength(3));
    expect(jsonDecode((await house.ask('GET', '/status')).$2), {'online': true, 'serving': 1}, reason: 'seating the pool');

    // The operator changes the clocks; the next wake says so, and the
    // pool's next seating has them.
    final later = TableTiming.parse({'graceMs': 6000});
    expect((await house.ask('POST', '/wake', {'table': 'ab' * 16}, {'timing': later.toJson()})).$1, 200, reason: 'a table\'s wake says them too');
    final you = SchnorrSigner.generate();
    final t2 = RelayTransport(relays: [relay.url], signer: you, table: poolTag('unrated'));
    await t2.ready;
    final again = WaitingRoom(relay: t2, pool: 'unrated', name: 'Bao', rating: 1500, house: _house);
    addTearDown(() {
      again.close();
      t2.close();
    });
    final next = again.seated.first;
    again.playWithBots();
    expect((await next.timeout(const Duration(seconds: 30))).timing, later);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a house whose secret is not the key the relay takes does not start', () async {
    final relay = Relay(house: _house);
    await relay.serve();
    addTearDown(relay.close);
    final house = await HouseProcess.start(relay, env: {'OH_HOUSE_KEY': 'ab' * 32});
    expect(await house.process.exitCode.timeout(const Duration(seconds: 60)), 1);
    expect(house.said.join('\n'), contains('not the secret of OH_HOUSE_KEY'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// The house's result for [table] as the results tag holds it, or null.
Future<NostrEvent?> storedResult(Relay relay, String table) async {
  final socket = WebSocketChannel.connect(relaysForTag([relay.url], GameResult.tag).single);
  await socket.ready;
  final got = <NostrEvent>[];
  final done = Completer<void>();
  socket.stream.listen((raw) {
    final m = jsonDecode(raw as String) as List;
    if (m[0] == 'EVENT') {
      final e = NostrEvent.parse(m[2]);
      if (e != null) got.add(e);
    }
    if (m[0] == 'EOSE' && !done.isCompleted) done.complete();
  });
  socket.sink.add(jsonEncode([
    'REQ',
    'r',
    {
      'kinds': [TableKinds.lobby],
      '#t': [GameResult.tag]
    }
  ]));
  await done.future.timeout(const Duration(seconds: 5));
  await socket.sink.close();
  for (final e in got) {
    if (GameResult.parse(e)?.table == table) return e;
  }
  return null;
}
