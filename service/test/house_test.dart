/// The house as it runs (service/bin/house.dart): a process of its own,
/// woken on its port for a table that wants it — as the Cloudflare
/// Container is, by the table's object (service/do/bench.mjs) — and
/// following the table from its log, on real sockets, with real keys.
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

  Future<(int, String)> ask(String method, String path, [Map<String, String>? query]) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, at(path, query));
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
