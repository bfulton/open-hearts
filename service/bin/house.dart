/// The house (docs/explanation/live-play.md): the operator's side of
/// every sealed table, in one process for all of them.
///
///     OH_HOUSE_SECRET=<64 hex> dart run bin/house.dart --relay ws://127.0.0.1:7448/{tag}
///     OH_HOUSE_SECRET=<64 hex> dart run bin/house.dart --relay wss://relay.openhearts.game/{tag} --port 8080
///
/// Woken for a table (`POST /wake?table=…`), it follows the table's log
/// from the first entry (packages/table, house.dart): it deals and plays
/// every bot seat, holds half of each person's escrow and says it when
/// that person goes, and once the game is over says how it came out —
/// in the log, which every side and every kept game checks it against,
/// and on the results tag, where the ratings are folded from. A table
/// the house was serving before it stopped wakes it again, and it goes
/// on from the log; its bot seats' deal secrets are made from its own
/// secret, so nothing is lost with the process.
///
/// Its port is for whatever runs it (service/do/bench.mjs, a Cloudflare
/// Container, which only the Worker that owns it can reach): `GET
/// /ping`; `GET /status`, {online, serving} — online while it was woken
/// in the last ten minutes or is serving a table, which is how the
/// container knows to stop it; and `POST /wake?table=…`. SIGTERM ends
/// it.
///
/// One secret is the whole of it, OH_HOUSE_SECRET, the relay worker's
/// own: the house's signing key, and the root of every deal secret it
/// makes. The relay carries it on its key alone (service/do/relay.mjs,
/// serviceGate) and referees sealed tables only for that key
/// (OH_HOUSE_KEY, config/openhearts.json); a house whose secret is not
/// that key's does not start. With OH_SERVICE_KEY it holds every seat to
/// its licence (packages/table, licence.dart), as every device does.
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:deal/deal.dart';
import 'package:table/table.dart';

/// How long a wake keeps the house online with nothing to serve: the
/// container is stopped once it has been quiet this long.
const awakeMs = 10 * 60 * 1000;

Future<void> main(List<String> args) async {
  final relays = <Uri>[];
  int? port;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) relays.addAll(Relays.parse(args[++i]));
    if (args[i] == '--port' && i + 1 < args.length) port = int.tryParse(args[++i]);
  }
  if (relays.isEmpty) relays.addAll(Relays.parse(Platform.environment['OH_RELAYS'] ?? ''));
  if (relays.isEmpty) relays.add(Uri.parse('ws://127.0.0.1:7448/$tagMark'));
  final secret = Platform.environment['OH_HOUSE_SECRET'] ?? '';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
    print('house: no OH_HOUSE_SECRET (64 hex); there is no house without its key');
    exit(1);
  }
  final native = await installNativeSchnorr();
  if (!native) print('schnorr: no native library (crypto/schnorr/build.sh); signatures in Dart, seventeen milliseconds each');
  final signer = SchnorrSigner.fromSecret(secret);
  final named = Platform.environment['OH_HOUSE_KEY'];
  if (named != null && named.isNotEmpty && named != signer.publicKey) {
    print('house: OH_HOUSE_SECRET is not the secret of OH_HOUSE_KEY, the house the relay takes; not starting');
    exit(1);
  }
  final service = Platform.environment['OH_SERVICE_KEY'] ?? '';
  if (RegExp(r'^[0-9a-f]{64}$').hasMatch(service)) licenceService = service;
  // The house shows the relay nothing but its answer, signed by its key.
  relayCredentials = (key) => key == signer.publicKey ? const [] : null;

  // The deal's cryptography: the cdylib built by crypto/deal/build.sh,
  // found beside the repository's own build. Every live table is
  // sealed; a house without it could serve none of them.
  final DealCrypto crypto;
  final DealWorker worker;
  try {
    crypto = await DealCrypto.load();
    worker = await DealWorker.start();
  } catch (e) {
    print('house: no deal cryptography ($e); every live table is sealed, so there is nothing to serve');
    exit(1);
  }
  final results = ResultPublisher(relays: relays, signer: signer, log: print);
  final house = House(
    signer: signer,
    secret: houseDealSecret(secret),
    lineFor: (table) => RelayLine(relays: relays, signer: signer, table: table, log: (line) => print('${table.substring(0, 8)} $line')),
    clock: WallClock(),
    crypto: crypto,
    dealWorker: worker,
    onResult: (result, signed) {
      print('${result.table.substring(0, 8)} over: ${result.state}');
      results.publish(signed);
    },
    trace: (table, line) => print('${table.substring(0, 8)} $line'),
  );
  print('house ${signer.publicKey.substring(0, 8)} on ${Relays.format(relays)}');
  var wokenAt = 0;
  bool online() => house.serving.isNotEmpty || DateTime.now().millisecondsSinceEpoch - wokenAt < awakeMs;
  void wake(String table) {
    wokenAt = DateTime.now().millisecondsSinceEpoch;
    if (house.serving.contains(table)) return;
    print('${table.substring(0, 8)} woken');
    house.serve(table);
  }

  if (port != null) await _answer(port, wake: wake, online: online, serving: () => house.serving.length);
  ProcessSignal.sigterm.watch().listen((_) {
    print('house: SIGTERM; going');
    house.close();
    results.close();
    worker.close();
    exit(0);
  });
}

/// The deal secret every bot seat's is made from (packages/table,
/// house.dart): the house's own secret, taken apart from its signing
/// key, so that neither says anything of the other.
Uint8List houseDealSecret(String secret) => Uint8List.fromList(sha256.convert(utf8.encode('open-hearts/house/deal\n$secret')).bytes);

/// The house's own port, for whatever runs it.
Future<void> _answer(int port, {required void Function(String table) wake, required bool Function() online, required int Function() serving}) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('house: answering on port $port');
  server.listen((request) async {
    final res = request.response;
    final path = request.uri.path;
    if (request.method == 'GET' && path == '/ping') {
      res.write('ok');
    } else if (request.method == 'GET' && path == '/status') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'online': online(), 'serving': serving()}));
    } else if (request.method == 'POST' && path == '/wake') {
      final table = request.uri.queryParameters['table'] ?? '';
      if (!validTableId(table)) {
        res.statusCode = HttpStatus.badRequest;
      } else {
        wake(table);
        res.write('awake');
      }
    } else {
      res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });
}

/// The house's results, said on the results tag until the relay has
/// them: through drops and restarts of the socket, each said again on
/// the next until the relay answers it.
class ResultPublisher {
  ResultPublisher({required List<Uri> relays, required this.signer, this.log}) {
    _connection = RelayConnection(
      url: relaysForTag(relays, GameResult.tag).first,
      subscriptions: const {},
      auth: relayAuthFor(signer),
      log: log,
      onMessage: _onMessage,
      onOpen: (c) {
        for (final e in _unsaid.values) {
          c.publish(e);
        }
      },
    );
  }

  final Signer signer;
  final void Function(String line)? log;
  late final RelayConnection _connection;
  final Map<String, NostrEvent> _unsaid = {};

  void publish(NostrEvent result) {
    _unsaid[result.id] = result;
    _connection.publish(result);
  }

  void _onMessage(RelayConnection from, List<Object?> m) {
    if (m[0] != 'OK' || m.length < 4 || _unsaid.remove(m[1]) == null) return;
    log?.call(m[2] == true ? 'result ${'${m[1]}'.substring(0, 8)} taken' : 'result ${'${m[1]}'.substring(0, 8)} refused: ${m[3]}');
  }

  void close() => _connection.close();
}
