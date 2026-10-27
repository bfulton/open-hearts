/// Real clients, real signatures, real sockets: tables played on the
/// relay the Cloudflare object runs, its referee keeping each table's
/// log (service/do/referee.mjs), on the wall clock.
///
/// The simulator plays the same tables on its own clock against its own
/// referee (packages/table_sim, sim_referee.dart) a thousand ways; this
/// is the same table meeting the real one: each side's line to it
/// (relay_line.dart), the house woken as the deployed object wakes it,
/// and the log a stranger reads afterwards checking as the game the
/// sides played.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:deal/memo.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// BIP-340's published pair: the service of these tests.
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// Waits for [what], [within] at most.
Future<void> until(String what, bool Function() holds, {Duration within = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(within);
  while (!holds()) {
    if (DateTime.now().isAfter(deadline)) fail(what);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The table's log as anybody reads it: a line of its own, from the
/// first entry, until it has caught up.
Future<List<LogEntry>> readLog(Relay relay, String table) async {
  final line = RelayLine(relays: [relay.url], signer: SchnorrSigner.generate(), table: table);
  final log = <LogEntry>[];
  line.open(0, log.add);
  await until('the log was not read', () => line.up, within: const Duration(seconds: 10));
  line.close();
  return log;
}

/// [event] said on [tag] over a socket of its own: the relay's answer.
Future<List<Object?>> say(Relay relay, String tag, NostrEvent event) async {
  final socket = WebSocketChannel.connect(relaysForTag([relay.url], tag).single);
  await socket.ready;
  final answer = socket.stream.map((raw) => jsonDecode(raw as String) as List<Object?>).firstWhere((m) => m[0] == 'OK' && m[1] == event.id);
  socket.sink.add(jsonEncode(['EVENT', event.toJson()]));
  final ok = await answer.timeout(const Duration(seconds: 5));
  await socket.sink.close();
  return ok;
}

/// A person's spec: [people] in seats 0 and 2, bots in the others.
TableSpec specFor(List<Signer> people, {bool sealed = false, PublicKey? house, int seed = 11}) => TableSpec(
      id: newTableId(),
      seed: seed,
      target: 1,
      sealed: sealed,
      house: house,
      seats: [
        HumanSeat(people[0].publicKey),
        const BotSeat(Persona.romeo),
        HumanSeat(people[1].publicKey),
        const BotSeat(Persona.juliet),
      ],
    );

void main() {
  setUpAll(() => installNativeSchnorr());

  test('two people and two bots play a game over the relay, and the log read alone is the game they played', () async {
    final relay = Relay();
    await relay.serve();
    addTearDown(relay.close);
    final people = [SchnorrSigner.generate(), SchnorrSigner.generate()];
    final spec = specFor(people);
    final clock = WallClock();
    final lines = [for (final p in people) RelayLine(relays: [relay.url], signer: p, table: spec.id)];
    final clients = [
      for (var i = 0; i < 2; i++) TableClient(tableId: spec.id, spec: spec, signer: people[i], line: lines[i], clock: clock),
    ];
    final started = DateTime.now();
    for (final c in clients) {
      c.start();
    }
    final players = [for (final c in clients) Player(c)];
    await until('the game did not end: ${clients.map((c) => c.rules.describe()).join(' / ')}', () => clients.every((c) => c.done));
    final took = DateTime.now().difference(started);
    for (final p in players) {
      p.stop();
    }
    final a = clients[0].rules, b = clients[1].rules;
    expect(a.state, TableState.finished);
    expect(b.state, a.state);
    expect(b.endHash, a.endHash, reason: 'the same log, entry for entry');
    expect(b.game.totals, a.game.totals);

    // Anybody, from the log alone, comes to the same game.
    final log = await readLog(relay, spec.id);
    expect(log.length, greaterThanOrEqualTo(a.endN!));
    final v = verifyRecord(GameRecord(spec: spec, log: log));
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.state, TableState.finished);
    expect(v.totals, a.game.totals);
    // Each person's start was sent; the first is the table's, and the
    // other is not in the log at all — and not said again either, once
    // the referee has said so.
    expect(log.where((e) => e.event?.kind == EventKind.start), hasLength(1));
    expect([for (final l in lines) l.unsaid], [0, 0]);
    // ignore: avoid_print
    print('a game over the relay: ${log.length} entries in ${took.inMilliseconds} ms');
    for (final c in clients) {
      c.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a sealed table wakes its house, which deals the bots, holds the escrow, and says how the game came out', () async {
    final crypto = await rememberedCrypto(kept: false);
    final houseKey = SchnorrSigner.generate();
    final results = <NostrEvent>[];
    final woken = <String>[];
    late House house;
    final relay = Relay(
      house: houseKey.publicKey,
      onWanted: (table) {
        woken.add(table);
        house.serve(table);
      },
    );
    await relay.serve();
    addTearDown(relay.close);
    final secret = Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
    house = House(
      signer: houseKey,
      secret: secret,
      lineFor: (table) => RelayLine(relays: [relay.url], signer: houseKey, table: table),
      clock: WallClock(),
      crypto: crypto,
      onResult: (_, signed) => results.add(signed),
    );
    addTearDown(house.close);

    final people = [SchnorrSigner.generate(), SchnorrSigner.generate()];
    final spec = specFor(people, sealed: true, house: houseKey.publicKey, seed: 12);
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
    await until('the game did not end: ${clients.map((c) => c.rules.describe()).join(' / ')}',
        () => clients.every((c) => c.done && c.rules.result != null), within: const Duration(minutes: 3));
    for (final p in players) {
      p.stop();
    }
    expect(woken.first, spec.id, reason: 'woken as the table started');
    final a = clients[0].rules;
    expect(a.state, TableState.finished);
    expect(clients[1].rules.endHash, a.endHash);
    expect(a.result!.author, houseKey.publicKey);

    // The kept game checks, the house's word on it and all.
    final log = await readLog(relay, spec.id);
    final v = verifyRecord(GameRecord(spec: spec, log: log), crypto: crypto, house: houseKey.publicKey);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.vouched, isTrue);
    expect(v.totals, a.game.totals);

    // The result the house would publish for the ratings is the game's,
    // and the results tag takes it from the house and from nobody else.
    await until('the house said no result', () => results.isNotEmpty, within: const Duration(seconds: 10));
    expect(results.single.pubkey, houseKey.publicKey);
    expect(GameResult.parse(results.single)!.toJson(), GameResult.ofTable(a)!.toJson());
    final fromPerson = GameResult.ofTable(a)!.signedBy(people[0]);
    expect((await say(relay, GameResult.tag, fromPerson))[2], isFalse, reason: 'a person\'s word on a result is nothing');
    expect((await say(relay, GameResult.tag, results.single))[2], isTrue);
    for (final c in clients) {
      c.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  group('on a relay that asks every device who it is', () {
    final shown = <PublicKey, Activation>{};
    Activation activationFor(PublicKey key, String account) {
      final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final unsigned = Activation(account: account, key: key, epoch: 1, until: until, signature: '');
      return Activation(account: account, key: key, epoch: 1, until: until, signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest));
    }

    setUp(() {
      relayCredentials = (key) => shown[key] == null
          ? null
          : [
              ['activation', jsonEncode(shown[key]!.toJson())],
            ];
    });
    tearDown(() {
      relayCredentials = null;
      shown.clear();
    });

    test('a device reloaded is noted gone and back by the referee, and plays its seat on from the log', () async {
      final relay = Relay(gate: _service);
      await relay.serve();
      addTearDown(relay.close);
      final people = [SchnorrSigner.generate(), SchnorrSigner.generate()];
      shown[people[0].publicKey] = activationFor(people[0].publicKey, '0a' * 16);
      shown[people[1].publicKey] = activationFor(people[1].publicKey, '0b' * 16);
      final spec = specFor(people, seed: 13);
      final clock = WallClock();
      TableClient seat(int i) => TableClient(
          tableId: spec.id, spec: spec, signer: people[i], line: RelayLine(relays: [relay.url], signer: people[i], table: spec.id), clock: clock);
      final ada = seat(0);
      var bao = seat(1);
      ada.start();
      bao.start();
      final adaPlays = Player(ada);
      var baoPlays = Player(bao);
      await until('the hand did not get going', () => ada.rules.moves.length >= 8);

      // Bao's page reloads: the line closes, and a new device of the same
      // key reads the log from its first entry and goes on.
      baoPlays.stop();
      bao.close();
      await until('the referee did not note Bao gone', () => ada.rules.down.containsKey(people[1].publicKey), within: const Duration(seconds: 10));
      bao = seat(1);
      bao.start();
      baoPlays = Player(bao);
      await until('the referee did not note Bao back', () => !ada.rules.down.containsKey(people[1].publicKey), within: const Duration(seconds: 10));
      await until('the game did not end: ${ada.rules.describe()} / ${bao.rules.describe()}', () => ada.done && bao.done);
      adaPlays.stop();
      baoPlays.stop();
      expect(ada.rules.state, TableState.finished, reason: 'nobody lost a seat to a reload');
      expect(ada.rules.removals, isEmpty);
      expect(bao.rules.endHash, ada.rules.endHash);
      final kinds = [
        for (final e in ada.rules.log)
          if (e.up != null) 'up' else if (e.down != null) 'down',
      ];
      expect(kinds, ['down', 'up']);
      ada.close();
      bao.close();
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  test('signalling goes to its addressee only, and sealed', () async {
    final relay = Relay();
    await relay.serve();
    addTearDown(relay.close);
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final c = SchnorrSigner.generate();
    final table = newTableId();
    final ta = RelayTransport(relays: [relay.url], signer: a, table: table);
    final tb = RelayTransport(relays: [relay.url], signer: b, table: table);
    final tc = RelayTransport(relays: [relay.url], signer: c, table: table);
    await Future.wait([ta.ready, tb.ready, tc.ready]);
    final atB = <Signal>[];
    final atC = <Signal>[];
    tb.signals.listen(atB.add);
    tc.signals.listen(atC.add);
    // An eavesdropper on the relay sees every signal at the table, and
    // reads none of it: each is sealed to its addressee (NIP-44).
    final overheard = <String>[];
    final ear = WebSocketChannel.connect(relaysForTag([relay.url], table).single);
    await ear.ready;
    ear.stream.listen((raw) {
      final m = jsonDecode(raw as String) as List;
      if (m[0] == 'EVENT') overheard.add((m[2] as Map)['content'] as String);
    });
    ear.sink.add(jsonEncode([
      'REQ',
      'ear',
      {
        'kinds': [TableKinds.signal],
        '#t': [table]
      }
    ]));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    ta.signal(b.publicKey, const Signal(from: '', type: 'offer', payload: {'sdp': 'v=0 …'}));
    ta.signal(b.publicKey, const Signal(from: '', type: 'ice', payload: {'candidate': 'candidate:1 …', 'sdpMid': '0'}));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(atB.map((s) => s.type), ['offer', 'ice']);
    expect(atB.first.from, a.publicKey);
    expect(atB.first.payload['sdp'], 'v=0 …');
    expect(atC, isEmpty);
    expect(overheard, hasLength(2));
    for (final content in overheard) {
      expect(content, isNot(contains('v=0')));
      expect(content, isNot(contains('candidate')));
      expect(base64.decode(content).first, Nip44.version);
    }
    ear.sink.close();
    // And the reply comes back the same way.
    tb.signal(a.publicKey, const Signal(from: '', type: 'answer', payload: {'sdp': 'v=0 answer'}));
    final answer = await ta.signals.first.timeout(const Duration(seconds: 5));
    expect(answer.type, 'answer');
    expect(answer.from, b.publicKey);
    for (final t in [ta, tb, tc]) {
      t.close();
    }
  });
}
