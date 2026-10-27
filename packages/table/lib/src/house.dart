/// The house: the operator's side of every live table
/// (docs/explanation/live-play.md).
///
/// It follows each table it is called to from the log's start, holds
/// every bot seat that is a bot when a hand begins and plays it, holds a
/// piece of every person's escrow and says it when that person goes, and
/// says how the game came out once it is over: the totals, and the log's
/// hash as it stood then (log.dart), which is what a kept game and a
/// rating are checked against. One key does all of it. The service runs
/// it as one process for every table (service/bin/house.dart); the
/// simulator runs it on its clock.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart' show seatCount;

import 'client.dart';
import 'clock.dart';
import 'nostr.dart';
import 'referee_line.dart';
import 'results.dart';
import 'signing.dart';
import 'spec.dart';

class House {
  House({
    required this.signer,
    required this.secret,
    required this.lineFor,
    required this.clock,
    this.crypto,
    this.dealWorker,
    this.onOver,
    this.onResult,
    this.random,
    this.onSide,
    this.trace,
  });

  final Signer signer;

  /// The house's own secret, every bot seat's deal secret is made from:
  /// the same after a restart, so a table carries on from its log.
  final Uint8List secret;

  /// A line to the referee of the table named, one per side the house
  /// plays there.
  final RefereeLine Function(String table) lineFor;

  final Clock clock;
  final DealCrypto? crypto;
  final DealWorker? dealWorker;

  /// Told when a table is over and the house's word on it is in the log:
  /// where the service publishes the result for the ratings.
  final void Function(TableClient follower)? onOver;

  /// Told the result of every game the house saw through to a finish or
  /// an end, signed, once its word on the end is in the log: what the
  /// service publishes on the results tag for the ratings (results.dart).
  /// None for a game that failed: nobody is rated on it.
  final void Function(GameResult result, NostrEvent signed)? onResult;

  /// What the house's sides draw from: a secure generator but in the
  /// simulator.
  final Random? random;

  /// Told of each side the house makes at a table, as it is made: a
  /// follower, and one for each bot seat it plays.
  final void Function(TableClient side)? onSide;

  final void Function(String table, String line)? trace;

  final Map<String, _Served> _tables = {};

  /// The tables being served now.
  Iterable<String> get serving => _tables.keys;

  /// Serves [table], if it is not served already: a follower, and a side
  /// for each seat the house plays, made as each seat becomes a bot's.
  void serve(String table) {
    if (_tables.containsKey(table)) return;
    final served = _Served(table);
    _tables[table] = served;
    final follower = TableClient(
      tableId: table,
      signer: signer,
      line: lineFor(table),
      clock: clock,
      role: Role.houseFollower,
      crypto: crypto,
      dealWorker: dealWorker,
      random: random,
      trace: (l) => trace?.call(table, 'house: $l'),
    );
    served.follower = follower;
    onSide?.call(follower);
    follower.changes.listen((_) => _look(served));
    follower.start();
  }

  void _look(_Served s) {
    final f = s.follower!;
    if (!f.started) return;
    if (f.rules.spec!.house != signer.publicKey) {
      trace?.call(s.table, 'house: the table names another house; not served');
      return _drop(s);
    }
    // A side for every seat a bot holds or will hold: the house plays it
    // in every hand it holds it from, and follows the table before that.
    for (var seat = 0; seat < seatCount; seat++) {
      if (f.rules.holders[seat] is! BotSeat || s.seats.containsKey(seat)) continue;
      final c = TableClient(
        tableId: s.table,
        signer: signer,
        line: lineFor(s.table),
        clock: clock,
        role: Role.houseSeat,
        seat: seat,
        crypto: crypto,
        dealWorker: dealWorker,
        houseSecret: secret,
        random: random,
        trace: (l) => trace?.call(s.table, 'house seat $seat: $l'),
      );
      s.seats[seat] = c;
      onSide?.call(c);
      c.start();
    }
    if (f.done && f.rules.result != null && !s.told) {
      s.told = true;
      onOver?.call(f);
      final result = GameResult.ofTable(f.rules);
      if (result != null) onResult?.call(result, result.signedBy(signer));
      _drop(s);
    }
  }

  void _drop(_Served s) {
    _tables.remove(s.table);
    s.follower?.close();
    for (final c in s.seats.values) {
      c.close();
    }
  }

  void close() {
    for (final s in List.of(_tables.values)) {
      _drop(s);
    }
  }
}

class _Served {
  _Served(this.table);
  final String table;
  TableClient? follower;
  final Map<int, TableClient> seats = {};
  bool told = false;
}
