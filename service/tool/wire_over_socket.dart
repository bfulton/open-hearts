/// What a sealed hand costs on a real socket to the relay: the bytes
/// that cross a TCP connection each way — envelopes and framing
/// included — and what the log is made of, entry by entry.
///
///     cd service && dart run tool/wire_over_socket.dart [think ms]
///
/// Two people and two bots at a sealed table, the house in this process
/// holding the bot seats, every side's socket through a proxy that
/// counts.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';

/// Forwards to [to] and counts what goes each way.
class Counter {
  Counter(this.to);

  final Uri to;
  int fromSides = 0;
  int fromRelay = 0;
  ServerSocket? _server;

  int get total => fromSides + fromRelay;

  /// The relay, through here, with the tag left for each side to put in.
  Uri get url => Uri(scheme: 'ws', host: '127.0.0.1', port: _server!.port, pathSegments: const [tagMark]);

  Future<void> start() async {
    final server = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((side) async {
      final up = await Socket.connect(to.host, to.port);
      side.listen((b) {
        fromSides += b.length;
        up.add(b);
      }, onDone: up.close, onError: (_) => up.close());
      up.listen((b) {
        fromRelay += b.length;
        side.add(b);
      }, onDone: side.close, onError: (_) => side.close());
    });
  }

  Future<void> close() async => _server?.close();
}

Future<void> main(List<String> args) async {
  await installNativeSchnorr();
  final crypto = await DealCrypto.load();
  final worker = await DealWorker.start();
  // How long a person takes over a card: the default plays a hand in
  // seconds; a real table is nearer a second or two.
  final thinkMs = args.isEmpty ? 20 : int.parse(args.first);
  print('a decision takes ${thinkMs}ms');

  final houseKey = SchnorrSigner.generate();
  late House house;
  final relay = Relay(house: houseKey.publicKey, onWanted: (table) => house.serve(table));
  await relay.serve();
  final proxy = Counter(Uri.parse('ws://127.0.0.1:${relay.port}'));
  await proxy.start();
  house = House(
    signer: houseKey,
    secret: Uint8List(32),
    lineFor: (table) => RelayLine(relays: [proxy.url], signer: houseKey, table: table),
    clock: WallClock(),
    crypto: crypto,
    dealWorker: worker,
  );

  final signers = [SchnorrSigner.generate(), SchnorrSigner.generate()];
  final spec = TableSpec(salt: newSalt(), seed: 5, sealed: true, target: 1, house: houseKey.publicKey, seats: [
    HumanSeat(signers[0].publicKey),
    HumanSeat(signers[1].publicKey),
    BotSeat(Persona.roster[3]),
    BotSeat(Persona.roster[4]),
  ]);
  final clients = [
    for (final s in signers)
      TableClient(
          tableId: spec.id, spec: spec, signer: s, line: RelayLine(relays: [proxy.url], signer: s, table: spec.id), clock: WallClock(), crypto: crypto),
  ];
  final players = [for (final c in clients) Player(c, thinkMs: thinkMs)];
  final began = DateTime.now();
  for (final c in clients) {
    c.start();
  }
  final done = Completer<void>();
  for (final c in clients) {
    c.changes.listen((_) {
      if (clients.every((c) => c.done && c.rules.result != null) && !done.isCompleted) done.complete();
    });
  }
  await done.future.timeout(const Duration(minutes: 5));
  final took = DateTime.now().difference(began);

  final log = clients.first.rules.log;
  final bytes = <String, int>{};
  final count = <String, int>{};
  for (final e in log) {
    final kind = switch (e) {
      LogEntry(:final event?) => event.kind.name,
      LogEntry(up: _?) || LogEntry(down: _?) => 'connection',
      LogEntry(unread: _?) => 'unread',
      _ => 'tick',
    };
    bytes[kind] = (bytes[kind] ?? 0) + utf8.encode(jsonEncode(e.toJson())).length;
    count[kind] = (count[kind] ?? 0) + 1;
  }
  print('a sealed hand: ${log.length} entries in ${took.inSeconds}s');
  print('  over the socket: ${proxy.total} bytes, ${proxy.fromSides} from the sides and the house, ${proxy.fromRelay} from the relay');
  for (final k in (bytes.keys.toList()..sort((a, b) => bytes[b]!.compareTo(bytes[a]!)))) {
    print('    ${k.padRight(10)} ${count[k].toString().padLeft(4)} entries, ${bytes[k]} bytes of log');
  }
  for (final p in players) {
    p.stop();
  }
  for (final c in clients) {
    c.close();
  }
  house.close();
  worker.close();
  await proxy.close();
  await relay.close();
  exit(0);
}
