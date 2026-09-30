/// A device's deal worker on the simulator's clock (packages/deal,
/// work.dart): a job is made at once, and its answer handed back after
/// the time it would take a browser — one job after another, in the
/// order they were sent, as a worker makes them.
///
/// Without one, the simulator makes every call where it is asked and
/// on no time at all; with one, a table waits on its work as a real
/// one does, and the steps kept for it are drained when it comes back.
library;

import 'package:deal/deal.dart';

import '../clock.dart';

class SimDealWorker implements DealWorker {
  SimDealWorker(this.crypto, this.clock, {this.costMs = browserMs});

  final DealCrypto crypto;
  final Clock clock;
  final int Function(DealJob job) costMs;

  /// A worker that has failed: every job fails, at once, as a real one
  /// whose wasm never loaded does.
  bool dead = false;

  /// A worker that has stopped: every job sent from here on is taken
  /// and never answered.
  bool hung = false;

  /// Jobs made, for tests.
  int made = 0;

  int _freeAt = 0;
  bool _closed = false;

  /// What each job takes in a browser on a desk: the medians of this
  /// build's deal.wasm in V8, the engine Chromium runs it in, on one
  /// core of a server with nothing else on it (docs/03-fair-deal.md,
  /// "Off the page's thread"). A batch of tokens goes by the card.
  static int browserMs(DealJob job) => switch (job) {
        InitialDeckJob() => 74,
        ShuffleJob() => 566,
        VerifyShuffleJob() => 468,
        RevealTokensJob(:final cards) => 51 * (cards.length ~/ maskedBytes) ~/ 10,
        VerifyTokensJob(:final cards) => 49 * (cards.length ~/ maskedBytes) ~/ 10,
      };

  @override
  void run(DealJob job, {required void Function(Object answer) done, required void Function(Object error) failed}) {
    if (_closed || dead) return failed(_closed ? 'closed' : 'the simulated worker is dead');
    if (hung) return;
    final start = clock.nowMs > _freeAt ? clock.nowMs : _freeAt;
    _freeAt = start + costMs(job);
    final answer = job.run(crypto);
    made++;
    clock.schedule(_freeAt - clock.nowMs, () {
      if (!_closed) done(answer);
    });
  }

  @override
  void close() => _closed = true;
}
