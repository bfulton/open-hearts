/// Runs the local service: the relay, and with `--juror` a backup juror
/// on it (docs/explanation/live-play.md) — in this process, which
/// is fine on a dev machine and wrong under load, since a relay
/// verifies every event it carries and a juror's client verifies them
/// again; `bin/juror.dart` runs one beside the relay instead, which is
/// what the browser suite does. Matchmaking is the players' own
/// business on the relay (packages/table, matching.dart).
///
///     cd service && dart run bin/service.dart            # relay on 7447
///     dart run bin/service.dart --port 0 --quiet         # any free port
///     dart run bin/service.dart --juror                  # and a juror
///
/// `OH_RELAY=js` runs the relay the Cloudflare object runs instead
/// (service/do/, docs/explanation/service.md), on the same port and saying the
/// same line, so anything that starts this process can be pointed at
/// either relay without knowing which it got.
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:service/service.dart';
import 'package:deal/deal.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  var port = 7447;
  var quiet = false;
  var juror = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) port = int.parse(args[++i]);
    if (args[i] == '--quiet') quiet = true;
    if (args[i] == '--juror') juror = true;
  }
  // Signatures through the native cdylib when it is built: the relay
  // checks every event it carries.
  final native = await installNativeSchnorr();
  if (!native) print('schnorr: no native library (crypto/schnorr/build.sh); signatures in Dart, seventeen milliseconds each');
  final relay = Relay(log: quiet ? null : print);
  await relay.serve(port: port);
  // Always say where, even when quiet: a test harness reads this line.
  print('relay ${relay.url}');
  if (juror) {
    // Its few lines are worth having even when the relay is quiet.
    // Every live table is sealed, so backup jurors without the deal could
    // serve none of them, and drawn it would hold bot seats and pieces
    // of escrow it never answers for (bin/juror.dart).
    final DealCrypto crypto;
    try {
      crypto = await DealCrypto.load();
    } catch (e) {
      print('juror: no deal cryptography ($e); every live table is sealed, so there is nothing to serve');
      await relay.close();
      exit(1);
    }
    // Several of them, because a table with bot seats needs
    // juryToHoldBots online before a juror can hold one at all, and
    // these are what answer when too few others are online
    // (docs/explanation/live-play.md).
    final bench = LastResortBench(
      signers: [for (var i = 0; i < juryToHoldBots; i++) SchnorrSigner.generate()],
      relays: [relay.url],
      log: print,
      crypto: crypto,
    );
    bench.start();
    print('backup jurors ${[for (final j in bench.jurors) j.presence.signer.publicKey.substring(0, 8)].join(' ')} listening');
  }
}
