/// Runs the local service: the relay, and the matchmaker on it.
///
///     cd service && dart run bin/service.dart            # relay on 7447
///     dart run bin/service.dart --port 0 --quiet         # any free port
library;

// A server's output is its log.
// ignore_for_file: avoid_print

import 'package:service/service.dart';

Future<void> main(List<String> args) async {
  var port = 7447;
  var quiet = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) port = int.parse(args[++i]);
    if (args[i] == '--quiet') quiet = true;
  }
  final relay = Relay(log: quiet ? null : print);
  await relay.serve(port: port);
  final matchmaker = Matchmaker(relayUrl: relay.url, log: quiet ? null : print);
  await matchmaker.start();
  // Always say where, even when quiet: a test harness reads this line.
  print('relay ${relay.url}');
}
