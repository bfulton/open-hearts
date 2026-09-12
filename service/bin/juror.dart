/// A juror of last resort on its own: quiet on the relay until a table
/// says it has nobody to draw a jury from, then online to serve it.
///
///     dart run bin/juror.dart --relay ws://localhost:7447
///     JUROR_SECRET=<64 hex> dart run bin/juror.dart --relay wss://…
///
/// A real key — a fresh one, or the secret given — so a public relay
/// takes its events; the local one takes anything.
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  var relay = 'ws://localhost:7447';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) relay = args[++i];
  }
  final secret = Platform.environment['JUROR_SECRET'];
  final signer = secret != null && secret.length == 64 ? SchnorrSigner.fromSecret(secret) : SchnorrSigner.generate();
  final juror = LastResortJuror(url: Uri.parse(relay), signer: signer, log: print);
  juror.start();
  print('juror of last resort ${signer.publicKey.substring(0, 8)} listening on $relay');
}
