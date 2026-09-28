/// How long a sealed hand takes to deal, and what the jury's own
/// waits cost in it.
///
///     dart run tool/time_to_deal.dart
///     dart run tool/time_to_deal.dart --seeds 20 --jury 6
///
/// A sealed deal is four rounds of turns between the people and the
/// jurors holding the bot seats, and nobody sees a card until the last
/// of them settles. That wait is the whole of what a person notices
/// about the deal, so it is worth a number rather than an impression —
/// and the client holds back in two places on purpose, which is what
/// this is here to price:
///
///  - a juror will not publish its seat's keys until the record has
///    said which draw the deal is sealed to — the first person's keys,
///    settled (`_checkSealed`). It used to wait two seconds for the
///    draw to stand still instead (`_juryFirmMs`); the record costs
///    three tenths of a second more to the first card, 6.90 s against
///    6.60 at a jury of ten over twenty seeds;
///  - a hand with bot seats waits for a jury big enough to hold them
///    (`_jurorsWaitMs`), which on a table with jurors about is over as
///    soon as the draw carries.
///
/// The simulator's clock is virtual, so these are the protocol's own
/// waits and latencies with no machine speed in them: the same seed
/// gives the same milliseconds every time.
///
/// What it found, at a jury of ten and twenty seeds: neither of those
/// two waits was what the time went on. The deal took 6.55 s when
/// nothing went missing and 15.41 s — fourteen hands in twenty —
/// when a juror was sent a bot seat's keys a moment before the jury
/// that vouches for them, refused the keys for that reason, and threw
/// them away. From there the only way back was somebody saying them
/// again, which the carry window held off for eight seconds. Keeping
/// the refused step and looking at it again when the jury lands
/// (packages/table, client.dart, `_onAction`) took every one of the
/// twenty to 6.6 s and, averaged over eight seeded hands, took
/// between a fifth and nearly half off the wire as well
/// (`tool/wire_in_sim.dart --seeds 8`): a peer that keeps what it was
/// sent does not have to be carried, and carrying is the expensive
/// thing.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  final crypto = await DealCrypto.load();
  int argOf(String name, int fallback) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? int.parse(args[i + 1]) : fallback;
  }

  final seeds = argOf('seeds', 12);
  final jurors = argOf('jury', jurySize + 4);
  final took = <int>[];
  final each = <({int seed, int ms})>[];
  var holding = 0;
  var sworn = 0;
  for (var seed = 1; seed <= seeds; seed++) {
    final t = SimTable(humans: 2, seed: seed, crypto: crypto, jurors: jurors);
    t.start();
    final dealt = t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 10 * 60 * 1000);
    if (!dealt) {
      print('seed $seed: never dealt');
      t.stop();
      continue;
    }
    took.add(t.clock.nowMs);
    each.add((seed: seed, ms: t.clock.nowMs));
    // And how much of the jury could do its job by then. A juror
    // holds a piece of each bot seat's secret only once it has read
    // that seat's keys out of the deal; one that missed a deal step
    // is carrying nothing, and could not open the seat if its holder
    // went — which is the one thing the jury is there for. Counted at
    // the moment the first card falls, which is when a holder can
    // first go.
    final hand = t.clients.first.game.handNumber;
    holding += t.jurors.where((j) => j.client?.holdsEscrowPiece(hand) ?? false).length;
    sworn += t.jurors.length;
    t.stop();
  }
  took.sort();
  if (took.isEmpty) {
    print('nothing dealt');
    return;
  }
  final mean = took.reduce((a, b) => a + b) / took.length;
  print('two people, two bot seats, a jury of $jurors, ${took.length} of $seeds hands dealt');
  print('  first card in ${(took.first / 1000).toStringAsFixed(2)} s at best, '
      '${(mean / 1000).toStringAsFixed(2)} s on average, '
      '${(took[took.length ~/ 2] / 1000).toStringAsFixed(2)} s in the middle, '
      '${(took.last / 1000).toStringAsFixed(2)} s at worst');
  print('  jurors holding a piece of the escrow when the first card fell: $holding of $sworn');
  print('  every hand, by seed: ${each.map((e) => '${e.seed}:${(e.ms / 1000).toStringAsFixed(2)}').join(' ')}');
}
