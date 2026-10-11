/// The bench as it runs in its container, against a real table: a
/// relay here, two people here, and the jurors of last resort wherever
/// they were started — in the image (service/bench), limited to the
/// Cloudflare instance it will run on, say. Nobody else is online, so
/// the table calls for jurors, the bench comes online, holds the two
/// bot seats and plays them, and this says how long each step took.
///
///     cd service && dart run tool/bench_check.dart --port 7449 [--hands 2]
///     docker run --rm --network host --cpus 0.25 --memory 1g \
///       -e OH_RELAYS=ws://127.0.0.1:7449 -e OH_PRESENCE_RELAYS=ws://127.0.0.1:7449 oh-bench:local
///
/// It waits for the bench to come up on the relay, so the two can be
/// started in either order. `--relay <url>` uses a relay already
/// running instead of starting one: the deployed object's, say, as
/// `node do/host.mjs --object` runs it, at `ws://127.0.0.1:7448/{tag}`.
library;

// A check's output is its log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  var port = 7449;
  var hands = 1;
  Uri? given;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) given = Relays.parse(args[++i]).single;
    if (args[i] == '--port' && i + 1 < args.length) port = int.parse(args[++i]);
    if (args[i] == '--hands' && i + 1 < args.length) hands = int.parse(args[++i]);
  }
  await installNativeSchnorr();
  final crypto = await DealCrypto.load();
  final relay = given == null ? DartRelay() : null;
  await relay?.serve(port: port);
  final url = given ?? Uri.parse('ws://127.0.0.1:$port');
  print('relay on $url; waiting for a table to be dealt');

  final signers = [SchnorrSigner.generate(), SchnorrSigner.generate()];
  final spec = TableSpec(id: 'bench-check-${DateTime.now().millisecondsSinceEpoch}', seed: 5, sealed: true, seats: [
    HumanSeat(signers[0].publicKey),
    HumanSeat(signers[1].publicKey),
    BotSeat(Persona.roster[3]),
    BotSeat(Persona.roster[4]),
  ]);
  final presences = [for (final s in signers) RelayPresence(relays: [url], signer: s)];
  final transports = [for (final s in signers) RelayTransport(relays: [url], signer: s, table: spec.id)];
  await Future.wait(transports.map((t) => t.ready));
  final clients = [
    for (var i = 0; i < 2; i++)
      TableClient(spec: spec, signer: signers[i], transport: transports[i], clock: WallClock(), presence: presences[i], crypto: crypto),
  ];
  final players = [for (final c in clients) Player(c, thinkMs: 800)];
  final began = DateTime.now();
  String at() => '${(DateTime.now().difference(began).inMilliseconds / 1000).toStringAsFixed(1)}s';
  var held = false;
  var dealt = -1;
  final done = Completer<bool>();
  for (final c in clients) {
    c.start();
    c.changes.listen((_) {
      if (!held && c.botHolders(c.game.handNumber).length == 2) {
        held = true;
        print('${at()}: the jury holds both bot seats: ${c.botHolders(c.game.handNumber).values.map((k) => k.substring(0, 8)).join(', ')}');
      }
      if (c.game.phase == Phase.passing && dealt < c.game.handNumber && identical(c, clients.first)) {
        dealt = c.game.handNumber;
        print('${at()}: hand $dealt dealt');
      }
      if (c.game.handNumber >= hands && !done.isCompleted) done.complete(true);
    });
  }
  final ok = await done.future.timeout(Duration(minutes: 10 * hands), onTimeout: () => false);
  print(ok ? '${at()}: $hands hand(s) played with the bench holding the bots' : 'FAIL: ${clients.first.describe()}');
  for (final p in players) {
    p.stop();
  }
  for (final c in clients) {
    c.close();
  }
  for (final p in presences) {
    p.close();
  }
  await relay?.close();
  exit(ok ? 0 : 1);
}
