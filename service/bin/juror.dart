/// The jurors of last resort on their own: quiet on the relay until a
/// table says it has nobody to draw a jury from, then online to serve
/// it.
///
///     dart run bin/juror.dart --relay ws://localhost:7447
///     OH_JUROR_SECRET=<64 hex> dart run bin/juror.dart --relay wss://a,wss://b
///     dart run bin/juror.dart --jurors 6      # a wider bench
///
/// Several of them, not one: a table whose bot seats the jury holds
/// needs juryToHoldBots jurors online before it can hold any, and the
/// call comes exactly when there is nobody else to make that number up
/// (docs/04-live-play.md). So the bench is that many by default, each
/// its own identity — derived from the secret given, so the same
/// deployment keeps the same keys across restarts, or fresh ones when
/// no secret is set.
///
/// Real keys so a public relay takes their events; the local one takes
/// anything. Several relays, comma-separated or `--relay` repeated, are
/// listened on together and written to one at a time (packages/table,
/// relays.dart).
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  final relays = <Uri>[];
  var size = juryToHoldBots;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) relays.addAll(Relays.parse(args[++i]));
    if (args[i] == '--jurors' && i + 1 < args.length) size = int.tryParse(args[++i]) ?? size;
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
  // by crypto/deal/build.sh, found from here or named by DEAL_LIB.
  DealCrypto? crypto;
  try {
    crypto = await DealCrypto.load();
  } catch (e) {
    print('juror: no deal cryptography ($e); sealed tables cannot be served');
  }
  final bench = LastResortBench(signers: signers, relays: relays, log: print, crypto: crypto);
  bench.start();
  final keys = [for (final s in signers) s.publicKey.substring(0, 8)].join(' ');
  print('jurors of last resort $keys listening on ${Relays.format(relays)}${crypto == null ? '' : ', sealed tables too'}');
}
