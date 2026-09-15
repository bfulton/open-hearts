/// Runs the local service: the relay, and with `--juror` the juror of
/// last resort on it (docs/04-live-play.md) — in this process, which
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
/// (service/do/, docs/06-service.md), on the same port and saying the
/// same line, so anything that starts this process can be pointed at
/// either relay without knowing which it got.
library;

// A server's output is its log.
// ignore_for_file: avoid_print

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
    DealCrypto? crypto;
    try {
      crypto = await DealCrypto.load();
    } catch (e) {
      print('juror: no deal cryptography ($e); sealed tables cannot be served');
    }
    final j = LastResortJuror(relays: [relay.url], signer: SchnorrSigner.generate(), log: print, crypto: crypto);
    j.start();
    print('juror of last resort ${j.presence.signer.publicKey.substring(0, 8)} listening');
  }
}
