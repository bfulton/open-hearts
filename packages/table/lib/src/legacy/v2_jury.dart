/// The jury of a game kept before the referee (v2_record.dart):
/// strangers drawn from whoever was online, per hand, to break a
/// deadlock the players at a table could not break themselves, and to
/// hold its bot seats.
///
/// Frozen: the verifier recomputes each hand's jury and bot holders
/// exactly as those builds drew them. The draw is a function of the
/// deal's own randomness, the hand and the snapshot of who was online
/// that the table agreed on. The first drawn is the foreman.
library;

import 'dart:math';

import '../signing.dart';

/// How many jurors a hand drew.
const jurySize = 6;

/// The draw, deterministic in [seed], [hand] and the [snapshot] of
/// keys online: everyone at the table computed the same list, and the
/// verifier computes it again.
List<PublicKey> drawJury(int seed, int hand, Iterable<PublicKey> snapshot, {int size = jurySize}) {
  final pool = snapshot.toSet().toList()..sort();
  var h = seed * 1000003 + hand * 7919;
  for (final k in pool) {
    for (final c in k.codeUnits) {
      h = (h * 31 + c) & 0x3fffffff;
    }
  }
  pool.shuffle(Random(h));
  return pool.take(size).toList();
}

/// The least jury that held any bot seat.
const juryToHoldBots = 4;

/// Which juror held which bot seat, one seat each, as every peer
/// computed it and the verifier computes it again: the foreman is
/// skipped, a jury under [juryToHoldBots] holds no seat, and seats
/// beyond the holders stay unassigned.
Map<int, PublicKey> assignBots(List<PublicKey> jury, Iterable<int> botSeats) {
  if (jury.length < juryToHoldBots) return const {};
  final seats = botSeats.toList()..sort();
  final holders = jury.skip(1).toList();
  return {
    for (var i = 0; i < seats.length && i < holders.length; i++) seats[i]: holders[i],
  };
}
