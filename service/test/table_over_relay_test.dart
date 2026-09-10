/// Real clients, real signatures, real sockets: table clients meeting
/// on the local relay and playing a hand, on the wall clock.
///
/// Slow by the standards of the simulator — every event is signed
/// twice (once as a table event, once as the relay envelope) and
/// verified by everyone — which is the point: this is the cost the
/// app pays, measured.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

/// Plays a seat the way a person would, from the client's own view.
class Player {
  Player(this.client) : bot = Bot() {
    _sub = client.changes.listen((_) => _react());
    _react();
  }

  final TableClient client;
  final Bot bot;
  StreamSubscription<void>? _sub;
  bool _thinking = false;

  void _react() {
    if (_thinking || !(client.awaitingMyPass || client.awaitingMyPlay)) return;
    _thinking = true;
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      _thinking = false;
      final seat = client.mySeat!;
      if (client.awaitingMyPass) {
        client.pass(bot.choosePass(client.game.handOf(seat)));
      } else if (client.awaitingMyPlay) {
        final view = BotView(
          seat: seat,
          hand: client.game.handOf(seat),
          trick: client.game.trick,
          played: client.played,
          heartsBroken: client.game.heartsBroken,
          isFirstTrick: client.game.isFirstTrick,
          taken: client.game.taken,
        );
        client.play(bot.chooseCard(view, client.game.legalPlaysFor(seat)));
      }
      _react();
    });
  }

  void stop() => _sub?.cancel();
}

void main() {
  late Relay relay;
  setUp(() async {
    relay = Relay();
    await relay.serve();
  });
  tearDown(() => relay.close());

  test('two people and two bots play a whole hand over the relay and hold the same record', () async {
    final signers = [SchnorrSigner.generate(), SchnorrSigner.generate()];
    final spec = TableSpec(id: 'relay-hand', seed: 11, seats: [
      HumanSeat(signers[0].publicKey),
      const BotSeat(Persona.romeo),
      HumanSeat(signers[1].publicKey),
      const BotSeat(Persona.juliet),
    ]);
    final transports = [for (final s in signers) RelayTransport(url: relay.url, signer: s, table: spec.id)];
    await Future.wait(transports.map((t) => t.ready));
    final clock = WallClock();
    final clients = [
      for (var i = 0; i < 2; i++) TableClient(spec: spec, signer: signers[i], transport: transports[i], clock: clock),
    ];
    final started = DateTime.now();
    for (final c in clients) {
      c.start();
    }
    final players = [for (final c in clients) Player(c)];

    // Until both have finished the first hand.
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!clients.every((c) => c.game.handNumber >= 1 || c.done)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the hand did not finish in time:\n${clients.map((c) => c.describe()).join()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final took = DateTime.now().difference(started);
    for (final p in players) {
      p.stop();
    }
    for (final c in clients) {
      expect(c.tableState, TableState.playing);
      expect(c.participants.length, 2);
    }
    final keys = [for (final c in clients) c.record.map((d) => d.key).toList()];
    expect(keys[0], keys[1], reason: 'both hold the same record');
    final v = verifyRecord(spec, clients.first.record, allowPartial: true);
    expect(v.ok, isTrue, reason: v.reason);
    // Every human decision was witnessed by the other: two signatures each.
    expect(clients.first.record.every((d) => d.removal || d.witnesses.length == 2), isTrue);
    // ignore: avoid_print
    print('a hand over the relay: ${clients.first.record.length} decisions in ${took.inMilliseconds} ms, '
        '${relay.stored} stored (ephemeral: none)');
    for (final c in clients) {
      c.close();
    }
    for (final t in transports) {
      t.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('signalling goes to its addressee only', () async {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final c = SchnorrSigner.generate();
    final ta = RelayTransport(url: relay.url, signer: a, table: 'sig');
    final tb = RelayTransport(url: relay.url, signer: b, table: 'sig');
    final tc = RelayTransport(url: relay.url, signer: c, table: 'sig');
    await Future.wait([ta.ready, tb.ready, tc.ready]);
    final atB = <Signal>[];
    final atC = <Signal>[];
    tb.signals.listen(atB.add);
    tc.signals.listen(atC.add);
    ta.signal(b.publicKey, const Signal(from: '', type: 'offer', payload: {'sdp': 'v=0 …'}));
    ta.signal(b.publicKey, const Signal(from: '', type: 'ice', payload: {'candidate': 'candidate:1 …', 'sdpMid': '0'}));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(atB.map((s) => s.type), ['offer', 'ice']);
    expect(atB.first.from, a.publicKey);
    expect(atB.first.payload['sdp'], 'v=0 …');
    expect(atC, isEmpty);
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
