/// How big a jury has to be, from what it is for.
///
///     dart run tool/jury_size.dart
///     dart run tool/jury_size.dart --target 0.00001   # five nines
///
/// The jury's size is an availability question, so it is answered as
/// one rather than argued. What a hand needs from its jury is this
/// (docs/04-live-play.md, packages/deal/lib/src/session.dart):
///
///  - **A bot seat whose holder goes** has to be opened from the
///    escrow. Today the escrow is the seat's key split in two, one
///    half of the jury holding each part — *both* halves must still
///    have somebody live, because the split is additive: every share
///    is needed (crypto/deal/src/lib.rs, `split`). That shape is
///    what makes this the binding case.
///  - **A person's seat whose owner goes** splits across the other
///    people and the jury, so it wants one live juror of any.
///  - **A deadlocked turn** wants one live juror to rule.
///
/// The one number this rests on is [f]: the chance that a juror drawn
/// at the start of a hand cannot be reached when its piece is wanted,
/// a minute or two later. There is no population to measure yet, so
/// the answer is given across a range of it and the design assumption
/// named in doc 04 rather than buried here.
///
/// And the honest caveat: this assumes jurors fail independently. What
/// takes every juror at once — a relay outage — no jury size divides,
/// which is the floor under all of these numbers.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'dart:math';

/// Doc 04: a person leaves in about 8% of hands.
const personLeaves = 0.08;

/// The most bot seats a table can have; a fourth would be a table with
/// nobody at it.
const mostBotSeats = 3;

/// The chance a hand cannot open a bot seat whose holder has gone,
/// with the escrow as it is built: the jury cut in two, every share of
/// a side needed, so a side with nobody live is a side that is gone.
double splitInHalves(int n, double f) {
  final a = (n + 1) ~/ 2;
  final b = n - a;
  var worst = 0.0;
  // The holders are the jury behind the foreman, so a holder may sit
  // in either half; the half it sits in has one fewer other. Take the
  // worse of the two, since the draw decides which and we do not.
  for (final inA in [true, false]) {
    final mine = (inA ? a : b) - 1;
    final other = inA ? b : a;
    if (mine < 0) continue;
    worst = max(worst, pow(f, mine) + pow(f, other) - pow(f, mine + other) as double);
  }
  return f * worst;
}

/// The same with a threshold escrow instead: the key in [n] Shamir
/// shares over the scalar field, any [t] of them enough. A share's
/// token scales by its (public) Lagrange coefficient and still adds,
/// so the key stays nowhere — the property the additive split was
/// chosen for survives. The seat is lost only when fewer than [t] of
/// the remaining jurors are live.
double threshold(int n, double f, int t) {
  var tooFew = 0.0;
  for (var live = 0; live < t; live++) {
    tooFew += binomial(n - 1, live) * pow(1 - f, live) * pow(f, n - 1 - live);
  }
  return f * tooFew;
}

double binomial(int n, int k) {
  var c = 1.0;
  for (var i = 0; i < k; i++) {
    c = c * (n - i) / (i + 1);
  }
  return c;
}

/// Everything a hand asks of its jury, together.
double handFails(int n, double f, {int? t, int botSeats = mostBotSeats}) {
  final perSeat = t == null ? splitInHalves(n, f) : threshold(n, f, t);
  var ok = pow(1 - perSeat, botSeats) as double;
  // A person's seat wants one live juror of any; a deadlock wants the
  // same. Both are the whole jury gone, which is small either way.
  ok *= 1 - personLeaves * pow(f, n);
  return 1 - ok;
}

int? least(double f, double target, {int? t}) {
  for (var n = 2; n <= 40; n++) {
    if (handFails(n, f, t: t) <= target) return n;
  }
  return null;
}

void main(List<String> args) {
  final at = args.indexOf('--target');
  final target = at >= 0 && at + 1 < args.length ? double.parse(args[at + 1]) : 0.00001;
  final fs = [0.01, 0.02, 0.05, 0.10, 0.20];
  print('a hand that cannot go on, per hand, at most $target — '
      '${(100 * (1 - target)).toStringAsFixed(3)}% of hands\n');

  print('--- the escrow as built: the jury in halves, every share of a side needed ---');
  print('f is a drawn juror unreachable when its piece is wanted, over one hand\n');
  print('   f      least jury    that hand-failure rate   at the jury of six we ship');
  for (final f in fs) {
    final n = least(f, target);
    final six = handFails(6, f);
    print('${(100 * f).toStringAsFixed(0).padLeft(4)}%'
        '${(n?.toString() ?? '>40').padLeft(14)}'
        '${(n == null ? '-' : handFails(n, f).toStringAsExponential(1)).padLeft(24)}'
        '${six.toStringAsExponential(1).padLeft(29)}');
  }

  for (final t in [2, 3]) {
    print('\n--- with a threshold escrow instead: any $t jurors of the whole jury ---');
    print('   f      least jury    that hand-failure rate   at the jury of six we ship');
    for (final f in fs) {
      final n = least(f, target, t: t);
      final six = handFails(6, f, t: t);
      print('${(100 * f).toStringAsFixed(0).padLeft(4)}%'
          '${(n?.toString() ?? '>40').padLeft(14)}'
          '${(n == null ? '-' : handFails(n, f, t: t).toStringAsExponential(1)).padLeft(24)}'
          '${six.toStringAsExponential(1).padLeft(29)}');
    }
  }

  print('\n--- what each size costs, for the trade (tool/wire_in_sim.dart) ---');
  print('a jury of  4: 1.21 MB handed over a hand');
  print('a jury of  6: 1.87 MB');
  print('a jury of  8: 4.14 MB');
  print('a jury of 10: 3.55 MB');
  print('a jury of 12: 7.73 MB');
}
