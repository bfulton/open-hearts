/// The deal's slow calls made in a worker (packages/deal, work.dart),
/// on the simulator: every device with a worker of its own that takes
/// a browser's time over each job ([SimDealWorker]).
///
/// What a worker must not change is the table: the same steps, checked
/// the same way, a record that checks out. What it must change is
/// where the time goes — none of the slow calls made on the thread the
/// table runs on. And a worker that fails, or stops, costs time and
/// nothing else.
@Tags(['slow'])
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

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
    // Any call made where the table runs would have been refused, and
    // raised in this test's zone, which fails it.
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
      expect(c.dealCallsRefused, 0, reason: '${c.signer.publicKey.substring(0, 6)} asked for a slow call nobody described');
    }
    // A person makes a shuffle and two batches of tokens, and checks
    // the other three shuffles and batches and the first deck, each
    // deal: ten a hand at the worker.
    final person = t.dealWorkers[t.signers.first.publicKey]!;
    expect(person.made, greaterThanOrEqualTo(10 * hands));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 20)));

  /// A one-hand game with [broken] done to the second person's worker
  /// before it starts; what was raised, and the table.
  (List<Object>, SimTable) oneHandWith(void Function(SimDealWorker w) broken) {
    final raised = <Object>[];
    late SimTable t;
    runZonedGuarded(() {
      t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1, workers: true);
      broken(t.dealWorkers[t.people[1].client.signer.publicKey]!);
      t.start();
      final first = t.people[0].client;
      t.clock.runUntil(() => first.done, limitMs: 20 * 60 * 1000);
    }, (e, _) => raised.add(e));
    return (raised, t);
  }

  void playedOnWithout(SimTable t, int seat) {
    final first = t.people[0].client;
    expect(first.done, isTrue, reason: 'the game was played out without it: ${first.describe()}');
    expect(first.record.any((d) => d.removal && d.event.seat == seat), isTrue, reason: 'the seat that could not deal was removed');
    final v = verifyRecord(t.spec, first.record, juries: first.juries, crypto: crypto, releases: first.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    for (final c in everyClient(t)) {
      expect(c.dealCallsRefused, 0);
    }
  }

  test('a worker that fails for good is a bug said out loud; its device leaves at once, and the table plays on', () {
    final (raised, t) = oneHandWith((w) => w.dead = true);
    final broken = t.people[1].client;
    expect(raised, [isA<DealWorkFailed>()], reason: 'the failure raised, once, and nothing else');
    expect(broken.cannotDeal, isNotNull, reason: 'and the device knows it cannot deal');
    expect(t.dealWorkers[broken.signer.publicKey]!.made, 0, reason: 'nothing was made anywhere for it');
    playedOnWithout(t, 1);
    expect(t.people[0].client.record.any((d) => d.removal && d.event.seat == 1 && d.event.kind == EventKind.leave), isTrue,
        reason: 'it left, rather than wait at a table of two to be booted at a turn that would never come');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a worker that stops answering is noticed stalling, replaced, given up on when that stalls too, and its device leaves', () {
    final (raised, t) = oneHandWith((w) => w.hung = true);
    expect(raised, [isA<DealWorkFailed>()]);
    expect(t.people[1].client.cannotDeal, contains('stalled'));
    playedOnWithout(t, 1);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  /// A one-hand game in which the worker of a juror holding a bot seat
  /// fails once [when] says; what was raised, the table, the juror.
  (List<Object>, SimTable, SimJuror) holderBroken(bool Function(SimJuror holder, SimDealWorker worker) when) {
    final raised = <Object>[];
    late SimTable t;
    late SimJuror broken;
    runZonedGuarded(() {
      t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1, workers: true);
      t.start();
      final c = t.people[0].client;
      t.clock.runUntil(() => c.botHolders(c.game.handNumber).isNotEmpty, limitMs: 60 * 1000);
      final holder = c.botHolders(c.game.handNumber).values.first;
      broken = t.jurors.firstWhere((j) => j.signer.publicKey == holder);
      final worker = t.dealWorkers[holder]!;
      t.clock.runUntil(() => when(broken, worker), limitMs: 60 * 1000);
      worker.dead = true;
      t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 20 * 60 * 1000);
    }, (e, _) => raised.add(e));
    return (raised, t, broken);
  }

  test('a juror whose worker fails while it serves stops serving; the seat it held goes to the escrow, and the game goes on', () {
    final (raised, t, broken) = holderBroken((j, w) => j.client != null && w.made > 0);
    expect(raised, [isA<DealWorkFailed>()]);
    expect(broken.client?.cannotDeal, isNotNull);
    expect(t.clients.every((c) => c.done), isTrue, reason: 'the game was played out: ${t.people[0].client.describe()}');
    checksOut(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a juror whose worker fails between its draw and its summons turns the summons down; the seat goes to the escrow', () {
    // The summons is on its way when the worker goes: the juror is
    // drawn, and holds a seat, but serves nothing — as the duty turns
    // down a sealed table it cannot deal at (juror_duty.dart).
    final (raised, t, broken) = holderBroken((j, w) => true);
    expect(broken.client, isNull, reason: 'no client started for a table it could not deal at');
    expect(raised, isEmpty, reason: 'nothing was asked of the broken worker');
    expect(t.clients.every((c) => c.done), isTrue, reason: 'the game was played out: ${t.people[0].client.describe()}');
    checksOut(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a device whose worker has failed is not online: no table draws it, and the jury comes from the others', () {
    // Three of the strangers online broken before the game: every live
    // table is sealed, so a device that cannot deal cannot serve one,
    // and drawn it would hold a bot seat and a piece of every escrow
    // it never answers for.
    final raised = <Object>[];
    late SimTable t;
    late Set<String> broken;
    runZonedGuarded(() {
      t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1, workers: true);
      broken = {for (final j in t.jurors.take(3)) j.signer.publicKey};
      for (final k in broken) {
        t.dealWorkers[k]!.dead = true;
      }
      t.start();
      t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 20 * 60 * 1000);
    }, (e, _) => raised.add(e));
    final c = t.people[0].client;
    expect(c.done, isTrue, reason: 'the game was played out: ${c.describe()}');
    final drawn = {for (final d in c.juries) ...d.event.jurors};
    expect(drawn, isNotEmpty);
    expect(drawn.intersection(broken), isEmpty, reason: 'drawn: $drawn');
    expect(raised, isEmpty, reason: 'nothing was asked of a broken worker');
    checksOut(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The sealed walks of chaos_sealed_test.dart, again with
  // every device's slow calls taking a browser's time at a worker:
  // steps waiting on work are steps held back, and the chaos is what
  // shakes out what holding them back does.
  for (final seed in [1, 2, 4]) {
    test('sealed chaos $seed with workers, nine strangers',
        () => expect(walkChaos(seed, crypto: crypto, jurors: 9, workers: true), isNull),
        timeout: const Timeout(Duration(minutes: 10)));
  }
}
