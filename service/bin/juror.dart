/// A juror of last resort on its own: quiet on the relay until a table
/// says it has nobody to draw a jury from, then online to serve it.
///
///     dart run bin/juror.dart --relay ws://localhost:7447
///     OH_JUROR_SECRET=<64 hex> dart run bin/juror.dart --relay wss://a,wss://b
///
/// A real key — a fresh one, or the secret given — so a public relay
/// takes its events; the local one takes anything. Several relays,
/// comma-separated or `--relay` repeated, are listened on together and
/// written to one at a time (packages/table, relays.dart).
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deal/deal.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  final relays = <Uri>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) relays.addAll(Relays.parse(args[++i]));
  }
  if (relays.isEmpty) relays.add(Uri.parse('ws://localhost:7447'));
  final native = await installNativeSchnorr();
  if (!native) print('schnorr: no native library (crypto/schnorr/build.sh); signatures in Dart, seventeen milliseconds each');
  final secret = Platform.environment['OH_JUROR_SECRET'];
  final signer = secret != null && secret.length == 64 ? SchnorrSigner.fromSecret(secret) : SchnorrSigner.generate();
  // The deal's cryptography, to serve sealed tables: the cdylib built
  // by crypto/deal/build.sh, found from here or named by DEAL_LIB.
  DealCrypto? crypto;
  try {
    crypto = await DealCrypto.load();
  } catch (e) {
    print('juror: no deal cryptography ($e); sealed tables cannot be served');
  }
  final juror = LastResortJuror(relays: relays, signer: signer, log: print, crypto: crypto);
  juror.start();
  print('juror of last resort ${signer.publicKey.substring(0, 8)} listening on ${Relays.format(relays)}${crypto == null ? '' : ', sealed tables too'}');
}
