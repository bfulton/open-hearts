/// The deal's slow calls made elsewhere (work.dart): the jobs, the
/// answers kept for the session, the VM's worker, and — the part that
/// matters — that what a session says it will call is what it calls.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deal/deal.dart';
import 'package:deal/memo.dart';
import 'package:test/test.dart';

Uint8List Function(String) wrapFor(String me) => (other) {
      final pair = [me, other]..sort();
      return Uint8List.fromList(sha256.convert(utf8.encode('fake-shared:${pair[0]}|${pair[1]}')).bytes);
    };

void main() {
  late DealCrypto d;
  setUpAll(() async => d = await rememberedCrypto());

  Uint8List bytes(Random r, int n) => Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  Uint8List flipped(Uint8List b, int at) => Uint8List.fromList(b)..[at] ^= 1;

  /// One of each job, on inputs that hold together.
  List<DealJob> oneOfEach() {
    final r = Random(5);
    final secrets = [for (var i = 0; i < 4; i++) bytes(r, 32)];
    final joint = d.aggregate([for (final s in secrets) d.keygen(s)]);
    final deck = d.initialDeck(joint);
    final shuffled = d.shuffle(joint, deck, bytes(r, 32));
    final cards = Uint8List.sublistView(shuffled.deck, 13 * maskedBytes);
    final tokens = d.revealTokens(secrets[0], cards, bytes(r, 32));
    return [
      InitialDeckJob(joint),
      ShuffleJob(joint, deck, bytes(r, 32)),
      VerifyShuffleJob(joint, deck, shuffled.deck, shuffled.proof),
      RevealTokensJob(secrets[0], cards, bytes(r, 32)),
      VerifyTokensJob(d.keygen(secrets[0]), cards, tokens),
    ];
  }

  test('a job is its call: made, sent as bytes and answered as bytes, it comes out the same', () {
    for (final job in oneOfEach()) {
      final answer = job.run(d);
      final again = DealJob.of(job.op, job.args);
      expect(again.key, job.key, reason: '${job.op}: the same call is the same key');
      expect(again.runtimeType, job.runtimeType);
      final back = job.answerFrom(DealJob.bytesOf(answer));
      switch (answer) {
        case ({Uint8List deck, Uint8List proof}) r:
          back as ({Uint8List deck, Uint8List proof});
          expect(back.deck, r.deck);
          expect(back.proof, r.proof);
        default:
          expect(back, answer, reason: job.op);
      }
    }
    final checks = oneOfEach().whereType<VerifyShuffleJob>().single;
    expect(checks.run(d), isTrue);
    expect(VerifyShuffleJob(checks.joint, checks.before, flipped(checks.after, 70), checks.proof).run(d), isFalse);
  });

  test('a key is the call, not the bytes\' home: equal inputs are equal keys, one bit apart are not', () {
    final job = oneOfEach()[2] as VerifyShuffleJob;
    final copy = VerifyShuffleJob(Uint8List.fromList(job.joint), Uint8List.fromList(job.before), Uint8List.fromList(job.after),
        Uint8List.fromList(job.proof));
    expect(copy.key, job.key);
    expect(VerifyShuffleJob(job.joint, job.before, job.after, flipped(job.proof, 0)).key, isNot(job.key));
    // The same bytes under another primitive are another call.
    expect(RevealTokensJob(job.joint, job.before, job.after).key, isNot(ShuffleJob(job.joint, job.before, job.after).key));
    // And where one input ends is part of the call.
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList([4]);
    expect(VerifyTokensJob(a, b, b).key, isNot(VerifyTokensJob(Uint8List.fromList([1, 2]), Uint8List.fromList([3, 4]), b).key));
  });

  test('answers put by are what the slow calls return, and a call with none is refused, out loud', () {
    final p = PreparedDeal(d, capacity: 3);
    final jobs = oneOfEach();
    final verify = jobs[2] as VerifyShuffleJob;
    // A made-up answer, to see it is the one returned: nobody but this
    // side's own worker ever puts one.
    p.put(verify, false);
    expect(p.verifyShuffle(verify.joint, verify.before, verify.after, verify.proof), isFalse);
    expect(p.refused, 0);
    // Nothing put by for this one: never made here. It is thrown — and
    // raised where a catch around the session could not swallow it.
    final deck = jobs[0] as InitialDeckJob;
    final raised = <Object>[];
    Object? thrown;
    runZonedGuarded(() {
      try {
        p.initialDeck(deck.joint);
      } catch (e) {
        thrown = e;
      }
    }, (e, _) => raised.add(e));
    expect(thrown, isA<UndescribedDealCall>());
    expect(raised, [isA<UndescribedDealCall>()], reason: 'raised, not only thrown');
    expect(p.refused, 1);
    // Kept to its capacity, the oldest going first.
    for (final j in [jobs[0], jobs[1], jobs[3]]) {
      p.put(j, j.run(d));
    }
    expect(p.has(verify), isFalse, reason: 'put by first, gone first');
    expect([jobs[0], jobs[1], jobs[3]].every(p.has), isTrue);
    // The quick calls go straight through.
    expect(p.keygen(Uint8List(32)..[31] = 7), d.keygen(Uint8List(32)..[31] = 7));
  });

  group('a whole deal answered from work described ahead', () {
    // Two people and two bot seats held by jurors — every seat with a
    // key of its own, as at a live table — and a juror following
    // without a seat. Each side has its own answers; a side's worker
    // here is simply the primitives, run when the side describes a
    // call and put by before the call is made.
    const jury = ['juror0', 'juror1', 'juror2', 'juror3'];
    final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), BotDealSeat(key: jury[0]), BotDealSeat(key: jury[1])];
    const keyOf = ['a', 'b', 'juror0', 'juror1', 'juror2'];

    List<DealSession> sides(DealCrypto Function() crypto) => [
          for (var i = 0; i < 5; i++)
            DealSession(
              crypto(),
              tableId: 'T1',
              tableSeed: 77,
              hand: 2,
              seats: seats,
              leadCard: 0,
              mySeat: i < 4 ? i : null,
              myKey: keyOf[i],
              wrap: wrapFor(keyOf[i]),
              custodians: jury,
              random: Random(300 + i),
            ),
        ];

    /// Deals among [all], [prepare]ing each side before every step it
    /// makes or takes; the hands each side ends with. [ownTokensLate]:
    /// a side's own thirteen tokens not made before it says its batch,
    /// so that it comes to them itself and asks.
    List<List<int>?> deal(List<DealSession> all, void Function(DealSession side, List<DealJob> jobs) prepare,
        {bool ownTokensLate = false}) {
      void asked(DealSession side) {
        while (side.wanted.isNotEmpty) {
          prepare(side, side.wanted);
          side.resume();
        }
      }

      // Work is described when a step is checked, and only then. What
      // taking it goes on to cost — the first deck — the session asks
      // for itself, and goes on once it is made, as the table has it.
      void everyone(int from, int round, Map<String, Object?> m, bool Function(DealSession x) take, {bool check = true}) {
        for (var i = 0; i < all.length; i++) {
          if (i == from) continue;
          if (check) prepare(all[i], all[i].workToTake(round, m));
          expect(take(all[i]), isTrue, reason: 'side $i took round $round from $from');
          asked(all[i]);
        }
      }

      // A table checks each step as it arrives and takes it only once
      // it settles, so a round's steps are all checked before any of
      // them is taken where the round allows: keys and tokens. The
      // shuffles go one at a time, each on the deck before it.
      final keys = [for (var s = 0; s < 4; s++) all[s].myKeys()!];
      for (var s = 0; s < 4; s++) {
        everyone(s, 0, keys[s], (x) => x.verifyKeys(keys[s]));
      }
      for (var s = 0; s < 4; s++) {
        everyone(s, 0, keys[s], (x) => x.acceptKeys(keys[s], verified: true), check: false);
      }
      for (var s = 0; s < 4; s++) {
        prepare(all[s], all[s].workToMake(1));
        final m = all[s].myShuffle()!;
        everyone(s, 1, m, (x) => x.verifyShuffle(m) && x.acceptShuffle(m, verified: true));
      }
      final tokens = <Map<String, Object?>>[];
      for (var s = 0; s < 4; s++) {
        final work = all[s].workToMake(2);
        prepare(all[s], ownTokensLate ? work.take(1).toList() : work);
        tokens.add(all[s].myTokens()!);
        asked(all[s]);
        everyone(s, 2, tokens[s], (x) => x.verifyTokens(tokens[s]));
      }
      for (var s = 0; s < 4; s++) {
        everyone(s, 2, tokens[s], (x) => x.acceptTokens(tokens[s], verified: true), check: false);
      }
      return [for (var s = 0; s < 4; s++) all[s].handOf(s)];
    }

    test('makes none of the slow calls on the side, and deals the hands it deals without', () {
      final prepared = <PreparedDeal>[];
      final withWork = deal(sides(() => (prepared..add(PreparedDeal(d))).last), (side, jobs) {
        final p = side.crypto as PreparedDeal;
        for (final j in jobs) {
          if (!p.has(j)) p.put(j, j.run(d));
        }
      });
      // A call not described would have been refused, and failed the
      // test where it was raised.
      for (var i = 0; i < prepared.length; i++) {
        expect(prepared[i].refused, 0, reason: 'side $i asked for a slow call it had not described');
      }
      final plain = deal(sides(() => d), (_, __) {});
      expect(withWork, plain, reason: 'the same seeds, the same deal, with the calls made elsewhere or not');
      for (final h in withWork) {
        expect(h, hasLength(13));
      }
    });

    test('a side that comes to its own cards before their tokens are made asks, and opens them once they are', () {
      final all = sides(() => PreparedDeal(d));
      final hands = deal(all, (side, jobs) {
        final p = side.crypto as PreparedDeal;
        for (final j in jobs) {
          if (!p.has(j)) p.put(j, j.run(d));
        }
      }, ownTokensLate: true);
      for (var i = 0; i < all.length; i++) {
        expect((all[i].crypto as PreparedDeal).refused, 0);
      }
      expect(hands, deal(sides(() => d), (_, __) {}), reason: 'the hands, all four, as dealt with nothing made elsewhere');
    });

    test('a step that fails its check describes the check it fails, and the answer is the check\'s', () {
      final all = sides(() => PreparedDeal(d));
      void made(DealSession side, List<DealJob> jobs) {
        for (final j in jobs) {
          (side.crypto as PreparedDeal).put(j, j.run(d));
        }
      }

      for (var s = 0; s < 4; s++) {
        final m = all[s].myKeys()!;
        for (var i = 0; i < all.length; i++) {
          if (i == s) continue;
          all[i].acceptKeys(m);
          made(all[i], all[i].wanted);
          all[i].resume();
        }
      }
      made(all[0], all[0].workToMake(1));
      final m = all[0].myShuffle()!;
      final bad = {...m, 'deck': base64.encode(flipped(base64.decode(m['deck'] as String), 200))};
      final work = all[1].workToTake(1, bad);
      expect(work, hasLength(1));
      expect(work.single.run(d), isFalse, reason: 'described, and made, it is the check that fails');
      (all[1].crypto as PreparedDeal).put(work.single, false);
      expect(all[1].verifyShuffle(bad), isFalse);
      expect(all[1].workToTake(1, {...m, 'seat': 2}), isEmpty, reason: 'not seat 2\'s turn: refused before any slow call');
      expect(all[1].workToTake(1, {'seat': 0, 'deck': 'not base64!'}), isEmpty);
    });
  });

  group('a worker kept going', () {
    // Workers that answer, fail or say nothing, as told, and ticks that
    // come when the test says.
    late List<_Fake> made;
    late void Function() tick;
    Future<ResilientDealWorker> keep(List<_Mode> modes, {int stallTicks = 3}) async {
      made = [];
      final w = await ResilientDealWorker.start(() async {
        if (made.length >= modes.length) throw StateError('no more workers');
        final f = _Fake(modes[made.length]);
        made.add(f);
        if (f.mode == _Mode.neverStarts) return Completer<DealWorker>().future;
        return f;
      }, stallTicks: stallTicks, every: (_, f) {
        tick = f;
        return () => tick = () {};
      });
      return w as ResilientDealWorker;
    }

    test('one that fails is replaced once, and the job waiting on it is answered by the next', () async {
      final w = await keep([_Mode.fail, _Mode.answer]);
      final job = oneOfEach().first;
      expect(await _run(w, job), 'made ${job.op}');
      expect(w.replaced, 1);
      expect(w.dead, isFalse);
    });

    test('one whose replacement fails too is dead, says why, and fails what waits and what comes', () async {
      final w = await keep([_Mode.fail, _Mode.fail]);
      final job = oneOfEach().first;
      await expectLater(_run(w, job), throwsA(contains('so did the worker started to replace')));
      expect(w.dead, isTrue);
      await expectLater(_run(w, job), throwsA(contains('so did the worker started to replace')));
      expect(made, hasLength(2), reason: 'replaced once, not again and again');
    });

    test('one whose replacement will not start is dead', () async {
      final w = await keep([_Mode.fail]);
      await expectLater(_run(w, oneOfEach().first), throwsA(contains('did not start')));
      expect(w.dead, isTrue);
    });

    test('a stall is work waiting and nothing finished, counted in ticks; then it is replaced', () async {
      final w = await keep([_Mode.hang, _Mode.answer]);
      final job = oneOfEach().first;
      final answer = _run(w, job);
      tick();
      tick();
      await pumpEventQueue();
      expect(w.replaced, 0, reason: 'two ticks are not three');
      tick();
      expect(await answer, 'made ${job.op}');
      expect(w.replaced, 1);
    });

    test('a replacement that never finishes starting is a stall too, and then the worker is dead', () async {
      final w = await keep([_Mode.fail, _Mode.neverStarts]);
      final answer = _run(w, oneOfEach().first);
      await pumpEventQueue();
      expect(w.replaced, 1, reason: 'the first failed, and one was started to replace it');
      tick();
      tick();
      tick();
      await expectLater(answer, throwsA(contains('finished none')));
      expect(w.dead, isTrue);
    });

    test('ticks with nothing waiting, or with jobs finishing, are not a stall', () async {
      final w = await keep([_Mode.answer]);
      for (var i = 0; i < 10; i++) {
        tick();
      }
      for (var i = 0; i < 10; i++) {
        await _run(w, oneOfEach().first);
        tick();
      }
      expect(w.replaced, 0);
      expect(w.dead, isFalse);
    });
  });

  group('the VM\'s worker', () {
    test('makes each job as it is made here, in an isolate', () async {
      final w = await DealWorker.start();
      addTearDown(w.close);
      for (final job in oneOfEach()) {
        final answer = await _run(w, job);
        expect(DealJob.bytesOf(answer), DealJob.bytesOf(job.run(d)), reason: job.op);
      }
    });

    test('a library that is not there is a worker that never starts, and says why', () async {
      await expectLater(DealWorker.start(libraryPath: '/nowhere/libdeal.so'), throwsA(contains('did not load')));
      final w = await DealWorker.start();
      w.close();
      await expectLater(_run(w, oneOfEach().first), throwsA(anything), reason: 'nor does a closed one make anything');
    });
  });
}

Future<Object> _run(DealWorker w, DealJob job) {
  final c = Completer<Object>();
  w.run(job, done: c.complete, failed: (e) => c.completeError(e.toString()));
  return c.future;
}

enum _Mode { answer, fail, hang, neverStarts }

/// A worker that answers every job with a string naming it, fails
/// every job, or says nothing at all — or never finishes starting.
class _Fake implements DealWorker {
  _Fake(this.mode);
  final _Mode mode;
  bool closed = false;

  @override
  bool get dead => false;

  @override
  void run(DealJob job, {required void Function(Object answer) done, required void Function(Object error) failed}) {
    switch (mode) {
      case _Mode.answer:
        scheduleMicrotask(() => done('made ${job.op}'));
      case _Mode.fail:
        scheduleMicrotask(() => failed('it broke'));
      case _Mode.hang || _Mode.neverStarts:
    }
  }

  @override
  void close() => closed = true;
}
