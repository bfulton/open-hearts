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
///    escrow. It is the seat's key in Shamir shares, one to each
///    juror, any `escrowThreshold` of which rebuild it — so the seat
///    is lost only when fewer than that many are live. This is the
///    binding case.
///  - **A person's seat whose owner goes** splits across the other
///    people and the jury, so it wants one live juror of any.
///  - **A deadlocked turn** wants one live juror to rule.
///
/// The one number this rests on is [f]: the chance that a juror drawn
/// at the start of a hand cannot be reached when its piece is wanted,
/// a minute or two later. There is no population to measure yet, so
/// the answer is given across a range of it and the design assumption
/// named in docs/04-live-play.md rather than buried here.
///
/// And the honest caveat: this assumes jurors fail independently. What
/// takes every juror at once — a relay outage — no jury size divides,
/// which is the floor under all of these numbers.
library;

// A measurement's output is its log.
// ignore_for_file: avoid_print

import 'dart:math';

import 'package:engine/args.dart';

const ln2 = 0.6931471805599453;

/// A person leaves in about 8% of hands (docs/04-live-play.md).
const personLeaves = 0.08;

/// The most bot seats a table can have; a fourth would be a table with
/// nobody at it.
const mostBotSeats = 3;

/// The chance a hand cannot open a bot seat whose holder has gone: the
/// key in [n] Shamir shares, any [t] of them enough, so the seat is
/// lost only when fewer than [t] of the remaining jurors are live.
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
double handFails(int n, double f, {required int t, int botSeats = mostBotSeats}) {
  final perSeat = threshold(n, f, t);
  var ok = pow(1 - perSeat, botSeats) as double;
  // A given-up seat is also *said* by a juror rather than worked out
  // by every side. Its pieces are sealed to the jury, so no player can
  // open it and none can compute its moves: the seat wants one
  // custodian still reachable to play it on. That is the holder gone
  // and every other juror with it, f^n, which is smaller than the
  // threshold term above by a wide margin at any f worth shipping —
  // the dependency is real but it is not what decides the number.
  // What it costs in practice is a wait rather than a hand: when the
  // juror saying the moves goes, the next in the escrow's order takes
  // over once it has judged the first one quiet.
  ok *= pow(1 - pow(f, n), botSeats) as double;
  // A person's seat wants one live juror of any; a deadlock wants the
  // same. Both are the whole jury gone, which is small either way.
  ok *= 1 - personLeaves * pow(f, n);
  return 1 - ok;
}

int? least(double f, double target, {required int t}) {
  for (var n = 2; n <= 40; n++) {
    if (handFails(n, f, t: t) <= target) return n;
  }
  return null;
}

/// [f] from a lifetime, which is how the assumption actually comes:
/// "expect the p50 juror to last about a minute".
///
/// A juror's presence is taken as memoryless — a constant chance of
/// going per second. That is the conservative reading: real session
/// lengths are heavier in the tail, and a juror is drawn from people
/// who are *already* online, so a real draw is of survivors and does
/// better than this. Exponential assumes that evidence away.
double rateFromHalfLife(double seconds) => ln2 / seconds;

/// The chance one juror is gone by the time a hand of [seconds] is out.
double goneOver(double rate, double seconds) => 1 - exp(-rate * seconds);

/// A hand is p50 a minute and p90 two (docs/04-live-play.md).
const handP50 = 60.0;
const handP90 = 120.0;

/// What a juror's half-life means for the jury.
void lifetimes(double target, double halfLifeSeconds) {
  final rate = rateFromHalfLife(halfLifeSeconds);
  print('\n--- a juror lasting ${halfLifeSeconds.toStringAsFixed(0)}s at p50, hands of a minute and two ---');
  print('   hand          f     any 2 of n   any 3 of n');
  for (final t in [(name: 'p50, 1 min', s: handP50), (name: 'p90, 2 min', s: handP90)]) {
    final f = goneOver(rate, t.s);
    String col(int? n) => (n == null ? '>40' : n.toString()).padLeft(13);
    print('  ${t.name.padRight(14)}${(100 * f).toStringAsFixed(1).padLeft(5)}%'
        '${col(least(f, target, t: 2))}${col(least(f, target, t: 3))}');
  }

  // And what a jury of six delivers at that rate.
  print('\n   at a jury of six, hands of a minute:');
  final f = goneOver(rate, handP50);
  print('     any 2 of six      ${handFails(6, f, t: 2).toStringAsExponential(1)}');
  print('     any 3 of six      ${handFails(6, f, t: 3).toStringAsExponential(1)}');

  // The jury topped up: new jurors brought on as old ones go, each
  // given a share by live custodians (client.dart, _topUpJury). The
  // window is how long a dead juror goes unreplaced, which is a
  // question of heartbeats — they are five seconds apart — and not of
  // bandwidth: a top-up is one small event, and only when somebody
  // actually drops.
  print('\n--- the jury topped up, any 2 of it opening a seat ---');
  print('  replaced within        jury of 5   jury of 6   jury of 7   jury of 8');
  for (final every in [10.0, 5.0, 3.0, 2.0]) {
    final fw = goneOver(rate, every);
    final windows = handP50 / every;
    final line = StringBuffer('  ${every.toStringAsFixed(0).padLeft(13)}s   ');
    for (final n in [5, 6, 7, 8]) {
      final perHand = 1 - pow(1 - handFails(n, fw, t: 2), windows);
      line.write('${perHand.toStringAsExponential(1).padLeft(9)}   ');
    }
    print(line);
  }
}

/// The size, one assumption at a time.
///
/// The chain is: a bot seat's holder goes; the seat's cards are masked
/// and only its token opens them; so the escrow has to answer; so two
/// live custodians have to be there when it does. Each link has a
/// number under it, and the size falls straight out of the product.
/// This varies one at a time, so it is clear which one is load-bearing.
void sizeByAssumption(double target) {
  const baseSeats = mostBotSeats;
  const baseHalfLife = 60.0;
  const baseWindow = 5.0;
  const baseAnnounced = 0.0;

  int? size({int seats = baseSeats, double halfLife = baseHalfLife, double window = baseWindow, double announced = baseAnnounced}) {
    // A departure that is announced needs no waiting to be noticed, so
    // what is left to wait out is the share that is not.
    final w = window * (1 - announced);
    final f = goneOver(rateFromHalfLife(halfLife), w);
    final windows = w <= 0 ? 1.0 : handP50 / w;
    for (var n = 2; n <= 24; n++) {
      final perHand = 1 - pow(1 - handFails(n, f, t: 2, botSeats: seats), windows);
      if (perHand <= target) return n;
    }
    return null;
  }

  void row(String what, int? n) => print('  ${what.padRight(46)}${(n?.toString() ?? '>24').padLeft(6)}');

  print('\n--- the size, one assumption at a time ---');
  print('  base: 3 bot seats, a juror lasting 60s at p50, a dead one');
  print('  replaced within 5s, any two of the jury opening a seat\n');
  row('the base', size());
  print('');
  row('2 bot seats (two people at the table)', size(seats: 2));
  row('1 bot seat (three people)', size(seats: 1));
  print('');
  row('a juror lasting 2 min at p50', size(halfLife: 120));
  row('a juror lasting 5 min at p50', size(halfLife: 300));
  print('');
  row('replaced within 10s (two heartbeats)', size(window: 10));
  row('replaced within 2s', size(window: 2));
  print('');
  row('half of departures announced, not waited out', size(announced: 0.5));
  row('nine in ten announced', size(announced: 0.9));
  print('');
  row('announced 9/10, and drawn from seated players', size(announced: 0.9, halfLife: 300));
  row('the same at two bot seats', size(announced: 0.9, halfLife: 300, seats: 2));
  print('');
  // Unload events are not reliable — a backgrounded phone, a crash or
  // a dropped link fires nothing — so half announced is the sober
  // version of it, and the pair is what to design against.
  row('half announced, drawn from seated players', size(announced: 0.5, halfLife: 300));
  row('half announced, a juror lasting 2 min', size(announced: 0.5, halfLife: 120));
}

void main(List<String> args) {
  final target = doubleArg(args, 'target', 0.00001);
  final fs = [0.01, 0.02, 0.05, 0.10, 0.20];
  print('a hand that cannot go on, per hand, at most $target — '
      '${(100 * (1 - target)).toStringAsFixed(3)}% of hands');
  print('f is a drawn juror unreachable when its piece is wanted, over one hand');

  for (final t in [2, 3]) {
    print('\n--- any $t jurors of the whole jury ---');
    print('   f      least jury    that hand-failure rate   at a jury of six');
    for (final f in fs) {
      final n = least(f, target, t: t);
      final six = handFails(6, f, t: t);
      print('${(100 * f).toStringAsFixed(0).padLeft(4)}%'
          '${(n?.toString() ?? '>40').padLeft(14)}'
          '${(n == null ? '-' : handFails(n, f, t: t).toStringAsExponential(1)).padLeft(24)}'
          '${six.toStringAsExponential(1).padLeft(29)}');
    }
  }

  sizeByAssumption(target);
  lifetimes(target, doubleArg(args, 'juror-p50', 60));

  print('\n--- what each size costs, for the trade (tool/wire_in_sim.dart) ---');
  print('a jury of  4: 1.21 MB handed over a hand');
  print('a jury of  6: 1.87 MB');
  print('a jury of  8: 4.14 MB');
  print('a jury of 10: 3.55 MB');
  print('a jury of 12: 7.73 MB');
}
