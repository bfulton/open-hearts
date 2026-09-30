/// The deal's slow calls made in a worker (packages/deal, work.dart),
/// on the simulator: every device with a worker of its own that takes
/// a browser's time over each job ([SimDealWorker]).
///
/// What a worker must not change is the table: the same steps, checked
/// the same way, a record that checks out. What it must change is
/// where the time goes — none of the slow calls made on the thread the
/// table runs on. And a worker that fails, or stops, costs time and
/// nothing else.
library;

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  /// Every client there has been at [t]: the people's, and each
  /// juror's that was summoned.
  List<TableClient> everyClient(SimTable t) => [...t.clients, for (final j in t.jurors) ?j.client];

  void checksOut(SimTable t) {
    for (final c in t.clients) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
  }

  test('a game with a worker at every device makes none of the deal\'s slow calls where the table runs', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 30, workers: true);
    t.start();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 60 * 60 * 1000), isTrue,
        reason: 'the game was played out: ${t.clients.first.describe()}');
    final hands = t.clients.first.game.handNumber + 1;
    expect(hands, greaterThan(1), reason: 'more than one hand, so more than one deal');
    checksOut(t);
    final clients = everyClient(t);
    expect(clients.length, greaterThan(t.clients.length), reason: 'jurors served, and are held to it too');
    for (final c in clients) {
      expect(c.dealCallsMadeHere, 0, reason: '${c.signer.publicKey.substring(0, 6)} made a slow call itself');
    }
    // A person makes a shuffle and two batches of tokens, and checks
    // the other three shuffles and batches and the first deck, each
    // deal: ten a hand at the worker.
    final person = t.dealWorkers[t.signers.first.publicKey]!;
    expect(person.made, greaterThanOrEqualTo(10 * hands));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('a device whose worker fails makes its work itself, and the table deals as before', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1, workers: true);
    final failing = t.people[1].client;
    t.dealWorkers[failing.signer.publicKey]!.dead = true;
    final said = <String>[];
    failing.log = said.add;
    t.start();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue,
        reason: 'the game was played out: ${failing.describe()}');
    checksOut(t);
    expect(failing.dealCallsMadeHere, greaterThanOrEqualTo(10), reason: 'every slow call of the deal, made at home');
    expect(said.where((l) => l.contains('deal worker:') && l.contains('failed there')), isNotEmpty, reason: 'and said why');
    expect(t.clients.first.dealCallsMadeHere, 0, reason: 'the others\' workers were fine');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a worker that stops answering is waited on once, and then the work is made at home', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1, workers: true);
    final stuck = t.people[1].client;
    t.dealWorkers[stuck.signer.publicKey]!.hung = true;
    final said = <String>[];
    stuck.log = said.add;
    t.start();
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue,
        reason: 'the game was played out: ${stuck.describe()}');
    checksOut(t);
    expect(stuck.dealCallsMadeHere, greaterThanOrEqualTo(10), reason: 'every slow call of the deal, made at home in the end');
    expect(said.where((l) => l.contains('not back in ${TableClient.workerPatienceMs ~/ 1000} s')), hasLength(1),
        reason: 'given up on once, not a job at a time');
    // A stopped worker costs the seat one patience, which is half a
    // deal step's allowance, so it does not cost the seat.
    expect(TableClient.workerPatienceMs, lessThanOrEqualTo(TimeBank.standard.fixedMs ~/ 2));
    expect(t.clients.first.record.where((d) => d.removal), isEmpty, reason: 'nobody was booted for it');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The walks that found something in the sealed deal, again with
  // every device's slow calls taking a browser's time at a worker:
  // steps waiting on work are steps held back, and the chaos is what
  // shakes out what holding them back does.
  for (final seed in [1, 2, 4]) {
    test('sealed chaos $seed with workers, nine strangers',
        () => expect(walkChaos(seed, crypto: crypto, jurors: 9, workers: true), isNull),
        timeout: const Timeout(Duration(minutes: 10)));
  }
}
