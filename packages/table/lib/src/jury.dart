/// The jury: strangers drawn from whoever is online, per hand, to
/// break a deadlock the players at a table cannot break themselves
/// (docs/04-live-play.md, "The jury").
///
/// The draw is a function of the deal's own randomness, the hand and
/// a snapshot of who is online that the table agrees on, so nobody at
/// the table can steer it and nobody outside it can either. The first
/// drawn is the foreman; the others answer in order behind them.
library;

import 'dart:math';

import 'signing.dart';

/// How many jurors a hand draws. Doc 04 sizes it ("The sizing"): four
/// answers the escrow, whose exposure is the 8% of hands where
/// somebody leaves. Holding bot seats is the other role and wants six
/// — its exposure is every hand with a bot, and the count has to cover
/// the foreman standing aside and one seat per bot besides, which at
/// three bots leaves four with no spare at all. It stays four until a
/// juror really holds a seat, since a wider jury before then is escrow
/// pieces and connections bought for nothing.
const jurySize = 4;

/// The draw, deterministic in [seed], [hand] and the [snapshot] of
/// keys online: everyone at the table computes the same list from the
/// same proposal, and the verifier recomputes it afterwards.
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

/// Which juror holds which bot seat, one seat each
/// (docs/04-live-play.md, "Playing a seat nobody holds"). Deterministic
/// in the jury and the seats, so every peer computes the same
/// assignment from the same proposal and the verifier recomputes it
/// afterwards.
///
/// One seat each, because a juror holding two bot seats at a table of
/// one person holds twenty-six of the fifty-two cards and takes the
/// person's hand by subtraction — the leak this exists to close, one
/// seat over. The foreman is skipped: it decides whether somebody has
/// gone, and a seat of its own in the hand it is judging is a
/// conflict worth the one spare juror it costs.
///
/// Fewer jurors than bot seats leaves the last seats unassigned, and
/// that is the table's cue to wait for a bigger jury rather than to
/// seat a bot nobody holds.
Map<int, PublicKey> assignBots(List<PublicKey> jury, Iterable<int> botSeats) {
  final seats = botSeats.toList()..sort();
  final holders = jury.skip(1).toList();
  return {
    for (var i = 0; i < seats.length && i < holders.length; i++) seats[i]: holders[i],
  };
}

/// Who is online, and how to reach a juror before it follows a table.
/// The relay carries both (presence_relay.dart); the simulator keeps
/// a list.
abstract class Presence {
  /// Keys that have announced themselves within [withinMs], this
  /// device's included.
  Set<PublicKey> online({required int withinMs});

  /// Asks [juror] to follow a table: the summons carries the table's
  /// spec and the hand.
  void summon(PublicKey juror, Map<String, Object?> summons);

  /// Says that [table] found nobody to draw from, so that a juror of
  /// last resort can come online.
  void callForJuror(String table);
}
