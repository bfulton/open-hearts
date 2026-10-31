/// The ratings the bots a pool seats are chosen by (service/bin/house.dart):
/// every result the relays hold, folded (packages/table, results.dart,
/// Ledger), as a device folds them for its own rating
/// (app/lib/net/standing.dart), and every result the house says after.
library;

import 'dart:async';

import 'package:table/table.dart';

class Ratings {
  /// Read from [relays] as [signer], the house: the results it said are
  /// the ones that stand since the referee. A relay that has not
  /// answered in [first] is given up on, and the rest are waited for
  /// [rest] more, as a device waits for them.
  Ratings({
    required this.relays,
    required this.signer,
    this.first = const Duration(seconds: 8),
    this.rest = const Duration(seconds: 4),
    this.log,
  });

  final List<Uri> relays;
  final Signer signer;
  final Duration first;
  final Duration rest;
  final void Function(String line)? log;

  /// The ratings as far as they are folded: the bots' starting ones
  /// until [load] is done, and then, if the relays did not answer in
  /// time, still.
  Ledger ledger = Ledger(prior: botPrior);
  Future<void>? _loading;
  bool _loaded = false;

  /// Said while the results were still being read: folded once they
  /// are, unless the relay had it already.
  final List<GameResult> _meanwhile = [];

  /// Reads the results, once: the first call reads them, and every
  /// call has that read.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final t = RelayTransport(relays: relays, signer: signer, table: GameResult.tag);
    try {
      await t.ready.timeout(first);
      await t.allReady.timeout(rest).catchError((_) {});
      final read = Ledger.from(t.lobbySoFar, house: signer.publicKey, prior: botPrior);
      for (final r in _meanwhile) {
        if (!read.standing.any((s) => s.table == r.table)) read.apply(r);
      }
      ledger = read;
      log?.call('house: ratings of ${read.standing.length} games');
    } catch (e) {
      for (final r in _meanwhile) {
        ledger.apply(r);
      }
      log?.call('house: no ratings ($e); the bots at their starting ratings');
    } finally {
      _meanwhile.clear();
      _loaded = true;
      t.close();
    }
  }

  /// A game the house has just said the result of.
  void fold(GameResult result) {
    if (!result.licensed) return;
    if (_loaded) {
      ledger.apply(result);
    } else if (_loading != null) {
      _meanwhile.add(result);
    }
  }
}
