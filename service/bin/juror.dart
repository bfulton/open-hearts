/// The jurors of last resort on their own: quiet on the relay until a
/// table says it has nobody to draw a jury from, then online to serve
/// it.
///
///     dart run bin/juror.dart --relay ws://localhost:7447
///     OH_JUROR_SECRET=<64 hex> dart run bin/juror.dart --relay wss://a,wss://b
///     dart run bin/juror.dart --jurors 6      # a wider bench
///     dart run bin/juror.dart --relay wss://a --presence wss://b/{tag},wss://a --port 8080
///
/// `--presence` is where the bench says it is here and hears calls,
/// as a device's presence goes (app/lib/net/relays.dart); `--relay`
/// is where it follows the tables. With `--port`, it answers on that
/// port for whatever runs it (service/do/bench.mjs, a Cloudflare
/// Container): `GET /ping`, `GET /status` — {online, serving} — and
/// `POST /wake?table=…`, a call passed on, so the bench is online for
/// that table now rather than at its next call. SIGTERM ends it.
///
/// Several of them, not one: a table whose bot seats the jury holds
/// needs juryToHoldBots jurors online before it can hold any, and the
/// call comes exactly when there is nobody else to make that number up
/// (docs/04-live-play.md). So the bench is that many by default, each
/// its own identity — derived from the secret given, so the same
/// deployment keeps the same keys across restarts, or fresh ones when
/// no secret is set.
///
/// Real keys, since the deployed relay takes nothing else. Several
/// relays, comma-separated or `--relay` repeated, are listened on
/// together and written to one at a time (packages/table, relays.dart).
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  final relays = <Uri>[];
  final presence = <Uri>[];
  var size = juryToHoldBots;
  int? port;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) relays.addAll(Relays.parse(args[++i]));
    if (args[i] == '--presence' && i + 1 < args.length) presence.addAll(Relays.parse(args[++i]));
    if (args[i] == '--jurors' && i + 1 < args.length) size = int.tryParse(args[++i]) ?? size;
    if (args[i] == '--port' && i + 1 < args.length) port = int.tryParse(args[++i]);
  }
  if (relays.isEmpty) relays.add(Uri.parse('ws://localhost:7447'));
  final native = await installNativeSchnorr();
  if (!native) print('schnorr: no native library (crypto/schnorr/build.sh); signatures in Dart, seventeen milliseconds each');
  final secret = Platform.environment['OH_JUROR_SECRET'];
  // One key per seat on the bench. Derived rather than the secret
  // itself, so that one secret in the environment gives the whole
  // bench and every restart brings the same keys back.
  final signers = [
    for (var i = 0; i < size; i++)
      if (secret != null && secret.length == 64)
        SchnorrSigner.fromSecret(sha256Hex(utf8.encode('$secret|juror|$i')))
      else
        SchnorrSigner.generate(),
  ];
  // The deal's cryptography, to serve sealed tables: the cdylib built
  // by crypto/deal/build.sh, found beside the repository's own build.
  // Every live table is sealed, so a bench without it could serve none
  // of them: it would come online when called, be drawn, hold bot
  // seats and pieces of escrow, and turn every summons down. It does
  // not start.
  final DealCrypto crypto;
  try {
    crypto = await DealCrypto.load();
  } catch (e) {
    print('juror: no deal cryptography ($e); every live table is sealed, so there is nothing to serve');
    exit(1);
  }
  final bench = LastResortBench(
      signers: signers, relays: relays, presenceRelays: presence.isEmpty ? null : presence, log: print, crypto: crypto);
  bench.start();
  final keys = [for (final s in signers) s.publicKey.substring(0, 8)].join(' ');
  print('jurors of last resort $keys listening on ${Relays.format(relays)}'
      '${presence.isEmpty ? '' : ', present on ${Relays.format(presence)}'}');
  if (port != null) await _answer(bench, port);
  ProcessSignal.sigterm.watch().listen((_) {
    print('juror: SIGTERM; going');
    bench.close();
    exit(0);
  });
}

/// The bench's own port, for whatever runs it: whether it is up, what
/// it is serving, and a call passed on. Nothing here is anybody's to
/// reach but the host's: in a Cloudflare Container only the Worker
/// that owns it can open the port.
Future<void> _answer(LastResortBench bench, int port) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('juror: answering on port $port');
  server.listen((request) async {
    final res = request.response;
    final path = request.uri.path;
    if (request.method == 'GET' && path == '/ping') {
      res.write('ok');
    } else if (request.method == 'GET' && path == '/status') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'online': bench.online, 'serving': bench.serving}));
    } else if (request.method == 'POST' && path == '/wake') {
      final table = request.uri.queryParameters['table'];
      if (table == null || table.isEmpty || table.length > 128) {
        res.statusCode = HttpStatus.badRequest;
      } else {
        bench.wake(table);
        res.write('awake');
      }
    } else {
      res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });
}
