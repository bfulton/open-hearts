/// The jury: strangers drawn from whoever is online, per hand, to
/// break a deadlock the players at a table cannot break themselves
/// (docs/explanation/live-play.md).
///
/// The draw is a function of the deal's own randomness, the hand and
/// a snapshot of who is online that the table agrees on, so nobody at
/// the table can steer it and nobody outside it can either. The first
/// drawn is the foreman; the others answer in order behind them.
library;

import 'dart:math';

import '../signing.dart';

/// How many jurors a hand draws (docs/explanation/live-play.md): four
/// answers the escrow, whose exposure is the 8% of hands where
/// somebody leaves. Holding bot seats is the other role and wants six
/// — its exposure is every hand with a bot, and the count has to cover
/// the foreman standing aside and one seat per bot besides, which at
/// three bots leaves four with no spare at all. A juror holds a seat,
/// so six. Past that the count stops paying: what takes
/// every juror at once is a relay outage, which no number of jurors
/// divides, and relay diversity is the better buy.
const jurySize = 6;

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
/// (docs/explanation/live-play.md). Deterministic
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
/// The seats run out before the holders do: [juryToHoldBots] is the
/// least jury that holds any, and past the foreman that leaves three
/// — the most bot seats a table can have, since a fourth would be a
/// table with nobody at it. Fewer holders than seats would leave the
/// last ones unassigned, and those stay everyone's to compute, as
/// every bot seat is at a table with no jury to draw from.
///
/// Under [juryToHoldBots] no seat is held at all, and every bot seat
/// stays everyone's to compute. A bot seat's escrow is the jury's own,
/// any two of its members rebuilding the seat's secret: with the
/// holder gone the rest must still make two, or the seat can never be
/// opened again and the hand waits for a card nobody can play. Four is
/// the least that leaves one to spare beyond that after a holder goes.
const juryToHoldBots = 4;

Map<int, PublicKey> assignBots(List<PublicKey> jury, Iterable<int> botSeats) {
  if (jury.length < juryToHoldBots) return const {};
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

  /// Of those, the ones likely to still be there in a minute: keys
  /// that have been announcing for at least [forMs], or that say they
  /// are seated at a table and so have a game to finish.
  ///
  /// The draw takes whoever is online, which mixes somebody in the
  /// middle of a game with somebody glancing at the lobby, and a
  /// hand's escrow rests on the ones it draws still being there when
  /// a bot seat has to be opened (docs/explanation/live-play.md). Preferring
  /// the settled ones costs nothing and needs no
  /// agreement: a proposer may narrow its own candidates as it likes,
  /// since what the table checks is that each juror is somebody *it*
  /// has seen lately, over a much wider window.
  ///
  /// What this rests on is that presence is not memoryless — that
  /// somebody who has been here five minutes will likely be here in
  /// one. Session lengths generally are heavy-tailed that way; it is
  /// an assumption until there is a population to measure.
  Set<PublicKey> settled({required int withinMs, required int forMs});

  /// The account [key] belongs to, as its presence says: a table draws
  /// no juror from an account it seats, by whichever of the account's
  /// devices (docs/explanation/live-play.md). The key itself where nothing names
  /// one — an account of one device.
  String accountOf(PublicKey key);

  /// Asks [juror] to follow a table: the summons carries the table's
  /// spec and the hand.
  void summon(PublicKey juror, Map<String, Object?> summons);

  /// Says that [table] found nobody to draw from, so that a backup
  /// juror can come online.
  void callForJuror(String table);
}
