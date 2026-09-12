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

/// How many jurors a hand draws. Doc 04 sizes it: the jury is lost
/// only when every juror goes inside one replacement window.
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
