/// What a hand costs on the wire, counted where the count is exact.
///
///     dart run tool/wire_in_sim.dart
///
/// The simulator's clock is virtual and its network deterministic, so
/// the same seed gives the same bytes every time — which is what makes
/// a protocol change measurable. A real socket
/// (service/tool/wire_over_socket.dart) gives the true total, framing
/// and compression included, but swings a quarter either way between
/// runs, and a change worth twenty per cent cannot be seen through
/// that.
///
/// Two people and two bot seats the jury holds, one hand, said and
/// handed over: what a peer puts on the wire, and what the wire hands
/// to peers — the second being the first times however many are
/// listening.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';

Future<void> main(List<String> args) async {
  final crypto = await DealCrypto.load();
  // A peer that drops out for half a minute and comes back has to be
  // carried forward over everything it missed, which is the heaviest
  // thing anyone sends and the case worth measuring separately: with
  // `away`, seat 1 goes offline early in the hand and returns.
  final away = args.contains('--away');
  // And `--slow` gives the network a relay's latency rather than a
  // data channel's, which is what it takes for a peer to still be
  // behind when the jury's turn to answer comes round.
  final slow = args.contains('--slow');
  // Jury sizes to measure: the default sweep, or whatever is asked
  // for — `--jury 4,6,8,10` — since what a jury costs is half of
  // choosing how big it should be (tool/jury_size.dart is the other
  // half).
  final asked = args.indexOf('--jury');
  final sizes = asked >= 0 && asked + 1 < args.length ? [for (final n in args[asked + 1].split(',')) int.parse(n)] : const [4, 6];
  for (final jurors in sizes) {
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: jurors);
    if (slow) {
      t.net.minLatencyMs = 200;
      t.net.maxLatencyMs = 400;
    }
    t.start();
    if (away) {
      final who = t.people[1].client.signer.publicKey;
      t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000);
      t.net.goOffline(who);
      t.clock.advance(30000);
      t.net.comeOnline(who);
    }
    final ok = t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 20 * 60 * 1000);
    final net = t.net;
    print('--- 2 people, 2 bot seats, a jury of $jurors (hand reached: $ok) ---');
    print('said ${net.said} bytes, handed over ${net.handed} (${(net.handed / net.said).toStringAsFixed(1)}x)');
    final by = net.saidByKind.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in by.take(10)) {
      print('  said ${e.key.padRight(18)} ${e.value}');
    }
    t.stop();
  }
}
