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

import 'package:deal/deal.dart';
// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'package:engine/args.dart';
import 'package:engine/engine.dart';
import 'package:table_sim/table_sim.dart';

Future<void> main(List<String> args) async {
  final crypto = await DealCrypto.load();
  // A peer that drops out for half a minute and comes back has to be
  // carried forward over everything it missed, which is the heaviest
  // thing anyone sends and the case worth measuring separately: with
  // `away`, seat 1 goes offline early in the hand and returns.
  final away = flagArg(args, 'away');
  // And `--slow` gives the network a relay's latency rather than a
  // data channel's, which is what it takes for a peer to still be
  // behind when the jury's turn to answer comes round.
  final slow = flagArg(args, 'slow');
  // And `--quiet` takes a bot seat's own juror offline once the play
  // has begun, which is the case sealing the escrow to the jury put a
  // price on: the seat is given up, every custodian says its piece
  // sealed to the others, and one of them plays the seat out. An
  // ordinary hand gives nothing up and pays none of it.
  final quiet = flagArg(args, 'quiet');
  // Jury sizes to measure: the default sweep, or whatever is asked
  // for — `--jury 4,6,8,10` — since what a jury costs is half of
  // choosing how big it should be (tool/jury_size.dart is the other
  // half).
  final sizes = intsArg(args, 'jury', const [4, 6]);
  // And how many seeded hands to average over. One hand is exact —
  // the same seed gives the same bytes every time — but it is one
  // draw, and the draw decides things that move the total by half
  // either way: which seats the bots take, who is drawn to hold
  // them, which peers fall behind. A single hand is enough to
  // measure a protocol change that doubles the traffic and not one
  // that moves it a tenth, so a change of that size is read off an
  // average of several.
  final seeds = intArg(args, 'seeds', 1);
  for (final jurors in sizes) {
    var said = 0;
    var handed = 0;
    var dealt = 0;
    for (var seed = 7; seed < 7 + seeds; seed++) {
    final t = SimTable(humans: 2, seed: seed, crypto: crypto, jurors: jurors);
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
    if (quiet) {
      t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000);
      final c = t.clients.first;
      final held = c.botHolders(c.game.handNumber);
      if (held.isNotEmpty) t.net.goOffline(held.values.first);
    }
    final ok = t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 20 * 60 * 1000);
    if (ok) dealt++;
    said += t.net.said;
    handed += t.net.handed;
    for (final e in t.net.saidByKind.entries) {
      byKind[e.key] = (byKind[e.key] ?? 0) + e.value;
    }
    t.stop();
    }
    final n = seeds;
    print('--- 2 people, 2 bot seats, a jury of $jurors${quiet ? ', its holder gone' : ''} '
        '(${seeds == 1 ? 'hand reached: ${dealt == 1}' : '$dealt of $seeds hands reached'}) ---');
    print('said ${said ~/ n} bytes, handed over ${handed ~/ n} (${(handed / said).toStringAsFixed(1)}x)');
    final by = byKind.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in by.take(10)) {
      print('  said ${e.key.padRight(18)} ${e.value ~/ n}');
    }
    byKind.clear();
  }
}

/// Bytes by kind, summed over the seeds of one jury size.
final Map<String, int> byKind = {};
