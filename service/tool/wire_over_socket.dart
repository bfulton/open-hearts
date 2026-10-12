/// What a hand costs on a real socket, with the relay's compression on
/// and off. The table's own measurement (packages/table,
/// tool/wire_breakdown.dart) counts the JSON a hand is made of; this
/// one counts the bytes that actually cross a TCP connection —
/// envelopes, framing and permessage-deflate included.
///
///     cd service && dart run tool/wire_over_socket.dart
///
/// Two people and two bots at a sealed table, the bot seats held by
/// backup jurors, everything through a proxy that
/// counts. Run twice, and the difference is what the extension is
/// worth.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

/// Forwards to [to] and counts what goes each way.
class Counter {
  Counter(this.to);

  final Uri to;
  int fromClients = 0;
  int fromRelay = 0;
  HttpServer? _idle;
  ServerSocket? _server;

  int get total => fromClients + fromRelay;

  Uri get url => Uri(scheme: 'ws', host: 'localhost', port: _server!.port);

  Future<void> start() async {
    final server = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) async {
      final up = await Socket.connect(to.host, to.port);
      client.listen((b) {
        fromClients += b.length;
        up.add(b);
      }, onDone: up.close, onError: (_) => up.close());
      up.listen((b) {
        fromRelay += b.length;
        client.add(b);
      }, onDone: client.close, onError: (_) => client.close());
    });
  }

  Future<void> close() async {
    await _server?.close();
    await _idle?.close();
  }
}

Future<
    ({
      int bytes,
      int events,
      Duration took,
      Map<String, int> sent,
      Map<String, int> received,
      Map<String, int> byAuthor
    })> hand(
    {required bool compress, required DealCrypto crypto, int thinkMs = 20}) async {
  final relay = DartRelay()
    ..compress = compress
    ..tally = true;
  await relay.serve();
  final proxy = Counter(relay.url);
  await proxy.start();

  final signers = [FakeSigner('a'), FakeSigner('b')];
  final spec = TableSpec(id: 'wire', seed: 5, sealed: true, seats: [
    HumanSeat(signers[0].publicKey),
    HumanSeat(signers[1].publicKey),
    BotSeat(Persona.roster[3]),
    BotSeat(Persona.roster[4]),
  ]);
  // The backup jurors, which are what hold the two bot seats when
  // nobody else is online — which nobody is, here.
  final bench = LastResortBench(
    signers: [for (var i = 0; i < juryToHoldBots; i++) FakeSigner('bench$i')],
    relays: [proxy.url],
    crypto: crypto,
  )..start();
  final presences = [for (final s in signers) RelayPresence(relays: [proxy.url], signer: s)];
  final transports = [for (final s in signers) RelayTransport(relays: [proxy.url], signer: s, table: spec.id)];
  await Future.wait(transports.map((t) => t.ready));
  final clients = [
    for (var i = 0; i < 2; i++)
      TableClient(
          spec: spec,
          signer: signers[i],
          transport: transports[i],
          clock: WallClock(),
          presence: presences[i],
          crypto: crypto),
  ];
  final players = [for (final c in clients) Player(c, thinkMs: thinkMs)];
  for (final c in clients) {
    c.start();
  }

  final began = DateTime.now();
  final done = Completer<void>();
  final subs = [
    for (final c in clients)
      c.changes.listen((_) {
        if (c.game.handNumber >= 1 && !done.isCompleted) done.complete();
      }),
  ];
  await done.future.timeout(const Duration(minutes: 5));
  final took = DateTime.now().difference(began);
  final events = clients.first.record.length;
  final sent = Map.of(relay.sent);
  final got = Map.of(relay.received);
  final who = Map.of(relay.byAuthor);

  for (final s in subs) {
    await s.cancel();
  }
  for (final p in players) {
    p.stop();
  }
  for (final c in clients) {
    c.close();
  }
  for (final p in presences) {
    p.close();
  }
  bench.close();
  await proxy.close();
  await relay.close();
  return (bytes: proxy.total, events: events, took: took, sent: sent, received: got, byAuthor: who);
}

Future<void> main(List<String> args) async {
  await installNativeSchnorr();
  final crypto = await DealCrypto.load();
  // How long a person takes over a card. The default plays a hand in
  // seconds; a real table is nearer a second or two, and the two
  // differ in how much of the wire is a turn being said again while
  // it settles.
  final thinkMs = args.isEmpty ? 20 : int.parse(args.first);
  print('a decision takes ${thinkMs}ms');
  final off = await hand(compress: false, crypto: crypto, thinkMs: thinkMs);
  print('a hand, compression off: ${off.bytes} bytes over the socket, ${off.events} decisions, ${off.took.inSeconds}s');
  print('  the relay sent:     ${off.sent}');
  print('  the relay received: ${off.received}');
  final who = off.byAuthor.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final e in who) {
    print('    ${e.key.padRight(10)} ${e.value}');
  }
  final on = await hand(compress: true, crypto: crypto, thinkMs: thinkMs);
  print('a hand, compression on:  ${on.bytes} bytes over the socket, ${on.events} decisions, ${on.took.inSeconds}s');
  final saved = off.bytes - on.bytes;
  print('permessage-deflate saves $saved bytes, ${(100 * saved / off.bytes).round()}% of the wire');
  exit(0);
}
