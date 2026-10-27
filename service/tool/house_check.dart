/// The house as it runs in its container, against a real table: a relay
/// here, two people here, and the house wherever it was started — in
/// the image (service/bench), limited to the Cloudflare instance it will
/// run on, say. The relay wakes it on its port as the deployed object
/// does (service/do/bench.mjs), it deals and plays the two bot seats,
/// and this says how long each hand took.
///
///     cd service && OH_HOUSE_SECRET=<64 hex> dart run tool/house_check.dart --port 7449 [--hands 2]
///     docker run --rm --network host --cpus 0.5 --memory 4g \
///       -e OH_HOUSE_SECRET=<the same> -e OH_RELAYS='ws://127.0.0.1:7449/{tag}' oh-bench:local
///
/// The house answers on `--house` (http://127.0.0.1:8080 by default,
/// the image's port). It is woken once the table starts, so the two can
/// be started in either order: a wake that finds nothing listening is
/// made again on the table's next entry.
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
  var houseAt = Uri.parse('http://127.0.0.1:8080');
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) port = int.parse(args[++i]);
    if (args[i] == '--hands' && i + 1 < args.length) hands = int.parse(args[++i]);
    if (args[i] == '--house' && i + 1 < args.length) houseAt = Uri.parse(args[++i]);
  }
  final secret = Platform.environment['OH_HOUSE_SECRET'] ?? '';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
    print('house_check: set OH_HOUSE_SECRET to the house\'s secret (64 hex), as the house is started with');
    exit(2);
  }
  await installNativeSchnorr();
  final crypto = await DealCrypto.load();
  final house = SchnorrSigner.fromSecret(secret).publicKey;
  final began = DateTime.now();
  String at() => '${(DateTime.now().difference(began).inMilliseconds / 1000).toStringAsFixed(1)}s';
  final relay = Relay(
    house: house,
    onWanted: (table) async {
      final client = HttpClient();
      try {
        final res = await (await client.postUrl(houseAt.replace(path: '/wake', queryParameters: {'table': table}))).close();
        print('${at()}: the house woken: ${res.statusCode}');
      } catch (e) {
        print('${at()}: the house not woken ($e); again on the next entry');
      } finally {
        client.close();
      }
    },
  );
  await relay.serve(port: port);
  print('relay on ${relay.url}, the house ${house.substring(0, 8)} at $houseAt');

  final signers = [SchnorrSigner.generate(), SchnorrSigner.generate()];
  final spec = TableSpec(id: newTableId(), seed: 5, sealed: true, target: gameOverScore, house: house, seats: [
    HumanSeat(signers[0].publicKey),
    HumanSeat(signers[1].publicKey),
    BotSeat(Persona.roster[3]),
    BotSeat(Persona.roster[4]),
  ]);
  final clients = [
    for (final s in signers)
      TableClient(
          tableId: spec.id, spec: spec, signer: s, line: RelayLine(relays: [relay.url], signer: s, table: spec.id), clock: WallClock(), crypto: crypto),
  ];
  final players = [for (final c in clients) Player(c, thinkMs: 800)];
  var dealt = -1;
  final done = Completer<bool>();
  for (final c in clients) {
    c.start();
    c.changes.listen((_) {
      if (identical(c, clients.first) && c.game.phase == Phase.passing && dealt < c.game.handNumber) {
        dealt = c.game.handNumber;
        print('${at()}: hand $dealt dealt');
      }
      if ((c.game.handNumber >= hands || c.done) && !done.isCompleted) done.complete(c.rules.state != TableState.failed);
    });
  }
  final ok = await done.future.timeout(Duration(minutes: 10 * hands), onTimeout: () => false);
  print(ok ? '${at()}: $hands hand(s) played with the house holding the bots' : 'FAIL: ${clients.first.rules.describe()}');
  for (final p in players) {
    p.stop();
  }
  for (final c in clients) {
    c.close();
  }
  await relay.close();
  exit(ok ? 0 : 1);
}
