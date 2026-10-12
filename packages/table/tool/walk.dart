/// One chaos seed, walked with every client's trace kept.
///
///     dart run tool/walk.dart --seed 5            # sealed, which is the slow kind
///     dart run tool/walk.dart --seed 5 --seeded
///
/// `tool/chaos.dart` walks many seeds and says which broke an
/// invariant; this walks one and says what everybody did, which is
/// the next question and the one the tool above cannot answer. The
/// walk is deterministic, so the seed that broke there breaks here.
library;

import 'package:deal/deal.dart';
// A probe's whole output is its printing.
// ignore_for_file: avoid_print

import 'package:engine/args.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

Future<void> main(List<String> args) async {
  final seed = intArg(args, 'seed', 0);
  final crypto = flagArg(args, 'seeded') ? null : await DealCrypto.load();
  final sc = ChaosScenario(seed, crypto: crypto);
  final t = sc.table;
  t.start();
  for (final c in t.clients) {
    c.log = print;
  }
  for (final j in t.jurors) {
    j.client?.log = print;
  }
  sc.schedule();
  var next = 5000;
  while (t.clock.nowMs < sc.quietAt && !t.survivors.every((c) => c.done)) {
    t.clock.advanceTo(next);
    for (final j in t.jurors) {
      j.client?.log ??= print;
    }
    next += 5000;
  }
  sc.quiet();
  t.run();
  print('=== faults: ${sc.faults.join('; ')}');
  for (final c in t.survivors) {
    print('=== survivor ${c.signer.publicKey.substring(0, 6)}: ${c.describe()}');
    final h = c.game.handNumber;
    String k(PublicKey p) => p.substring(0, 4);
    print('=== holders ${c.botHolders(h).map((s, p) => MapEntry(s, k(p)))}; custodians ${c.custodiansOf(h).map(k).toList()}; '
        'up ${[for (final j in t.liveJurors) k(j.signer.publicKey)]}; waiting on a gone jury ${c.waitingOnGoneJury}');
  }
  for (final j in t.jurors) {
    print('=== juror ${j.signer.publicKey.substring(0, 6)} gone ${j.gone}: ${j.client?.describe() ?? 'no client'}');
  }
  // And what each survivor's record says for itself, which is the
  // verdict the walk gives when a finished game does not check out.
  for (final c in t.survivors) {
    final v = verifyRecord(t.spec, c.record, allowPartial: !c.done, juries: c.juries, crypto: t.crypto, releases: c.releases);
    print('=== ${c.signer.publicKey.substring(0, 6)} verifies ${v.ok ? (v.complete ? 'complete' : 'so far') : 'NOT: ${v.reason}'}');
  }
  final apart = disagreed(t);
  if (apart != null) print('=== $apart');
  t.stop();
}
