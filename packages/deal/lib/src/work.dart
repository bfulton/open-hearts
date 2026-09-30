/// The deal's slow calls, made somewhere other than the thread that
/// draws the screen.
///
/// Five of the primitives take long enough to be seen: a shuffle and
/// its argument, checking one, a seat's thirty-nine tokens and their
/// argument, checking those, and the deck before anyone shuffles. In a
/// browser on a desk they take from 74 ms, the deck, to 566, a
/// shuffle; a phone takes two or three times that; and on the thread
/// that draws the page each is that long of a page that does not move
/// and a tap that does not land. No other call the deal makes takes
/// fifteen.
///
/// So those five can be described rather than made ([DealJob]), made
/// by a [DealWorker] — a Web Worker in the browser, an isolate on the
/// VM — and handed back to the session through a [PreparedDeal], which
/// answers the call when it comes from what the worker made. The
/// session itself stays what it was: synchronous, and making any call
/// it was not handed the answer to itself. What it would have made is
/// what it is handed, bit for bit, since the worker runs the same
/// primitives on the same inputs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../deal.dart';
import 'worker_vm.dart' if (dart.library.js_interop) 'worker_web.dart' as platform;

/// One of the slow calls, described: which primitive and its inputs.
///
/// A job's [key] is a hash of both, so the same call asked for twice
/// — described ahead by the table, and then made by the session — is
/// the same key however its bytes were come by.
sealed class DealJob {
  DealJob();

  /// The primitive's name on the wire to a worker.
  String get op;

  /// Its inputs, in the order the primitive takes them.
  List<Uint8List> get args;

  /// Made here, with [crypto].
  Object run(DealCrypto crypto);

  /// The answer out of what a worker that speaks in bytes sent back.
  Object answerFrom(List<Uint8List> out);

  late final String key = () {
    final b = BytesBuilder(copy: false)..add(utf8.encode(op));
    for (final a in args) {
      b.add([a.length >> 24 & 0xff, a.length >> 16 & 0xff, a.length >> 8 & 0xff, a.length & 0xff]);
      b.add(a);
    }
    return sha256.convert(b.takeBytes()).toString();
  }();

  /// A job from its name and inputs, as a worker is sent it.
  static DealJob of(String op, List<Uint8List> a) => switch (op) {
        InitialDeckJob.name => InitialDeckJob(a[0]),
        ShuffleJob.name => ShuffleJob(a[0], a[1], a[2]),
        VerifyShuffleJob.name => VerifyShuffleJob(a[0], a[1], a[2], a[3]),
        RevealTokensJob.name => RevealTokensJob(a[0], a[1], a[2]),
        VerifyTokensJob.name => VerifyTokensJob(a[0], a[1], a[2]),
        _ => throw ArgumentError('no such job: $op'),
      };

  /// An answer as bytes, the way a worker that speaks in bytes sends
  /// it: the reverse of [answerFrom].
  static List<Uint8List> bytesOf(Object answer) => switch (answer) {
        bool b => [Uint8List.fromList([b ? 1 : 0])],
        Uint8List u => [u],
        ({Uint8List deck, Uint8List proof}) r => [r.deck, r.proof],
        _ => throw ArgumentError('no such answer: $answer'),
      };
}

/// [DealCrypto.initialDeck].
final class InitialDeckJob extends DealJob {
  InitialDeckJob(this.joint);
  static const name = 'initialDeck';
  final Uint8List joint;
  @override
  String get op => name;
  @override
  List<Uint8List> get args => [joint];
  @override
  Object run(DealCrypto crypto) => crypto.initialDeck(joint);
  @override
  Object answerFrom(List<Uint8List> out) => out.single;
}

/// [DealCrypto.shuffle].
final class ShuffleJob extends DealJob {
  ShuffleJob(this.joint, this.deck, this.seed);
  static const name = 'shuffle';
  final Uint8List joint;
  final Uint8List deck;
  final Uint8List seed;
  @override
  String get op => name;
  @override
  List<Uint8List> get args => [joint, deck, seed];
  @override
  Object run(DealCrypto crypto) => crypto.shuffle(joint, deck, seed);
  @override
  Object answerFrom(List<Uint8List> out) => (deck: out[0], proof: out[1]);
}

/// [DealCrypto.verifyShuffle].
final class VerifyShuffleJob extends DealJob {
  VerifyShuffleJob(this.joint, this.before, this.after, this.proof);
  static const name = 'verifyShuffle';
  final Uint8List joint;
  final Uint8List before;
  final Uint8List after;
  final Uint8List proof;
  @override
  String get op => name;
  @override
  List<Uint8List> get args => [joint, before, after, proof];
  @override
  Object run(DealCrypto crypto) => crypto.verifyShuffle(joint, before, after, proof);
  @override
  Object answerFrom(List<Uint8List> out) => out.single.length == 1 && out.single[0] == 1;
}

/// [DealCrypto.revealTokens].
final class RevealTokensJob extends DealJob {
  RevealTokensJob(this.secret, this.cards, this.seed);
  static const name = 'revealTokens';
  final Uint8List secret;
  final Uint8List cards;
  final Uint8List seed;
  @override
  String get op => name;
  @override
  List<Uint8List> get args => [secret, cards, seed];
  @override
  Object run(DealCrypto crypto) => crypto.revealTokens(secret, cards, seed);
  @override
  Object answerFrom(List<Uint8List> out) => out.single;
}

/// [DealCrypto.verifyTokens].
final class VerifyTokensJob extends DealJob {
  VerifyTokensJob(this.pk, this.cards, this.tokens);
  static const name = 'verifyTokens';
  final Uint8List pk;
  final Uint8List cards;
  final Uint8List tokens;
  @override
  String get op => name;
  @override
  List<Uint8List> get args => [pk, cards, tokens];
  @override
  Object run(DealCrypto crypto) => crypto.verifyTokens(pk, cards, tokens);
  @override
  Object answerFrom(List<Uint8List> out) => out.single.length == 1 && out.single[0] == 1;
}

/// The primitives, with the slow ones answered from jobs made
/// elsewhere when they were ([put]), and made here when they were not.
///
/// Nothing is taken on trust that was not made by the same primitives
/// on the same inputs: an answer is found by the hash of the call it
/// answers, and only this side's own worker puts one here.
class PreparedDeal implements DealCrypto {
  PreparedDeal(this.inner, {this.capacity = 64});

  final DealCrypto inner;

  /// How many answers are kept, the oldest going first. A hand asks
  /// for a dozen or so; a juror serving a few tables, a few dozen.
  final int capacity;

  final Map<String, Object> _answers = {};

  /// The slow calls made here for want of an answer: what the thread
  /// this runs on paid for itself. The table's tests hold it to none.
  int madeHere = 0;

  bool has(DealJob job) => _answers.containsKey(job.key);

  void put(DealJob job, Object answer) {
    _answers.remove(job.key);
    _answers[job.key] = answer;
    while (_answers.length > capacity) {
      _answers.remove(_answers.keys.first);
    }
  }

  /// Handed out as copies: an answer can be asked for twice — a deal
  /// built again for the same hand asks for the same first deck — and
  /// what one caller writes into must not be the next one's answer.
  Object _answer(DealJob job) {
    final a = _answers[job.key];
    if (a != null) {
      return switch (a) {
        Uint8List b => Uint8List.fromList(b),
        ({Uint8List deck, Uint8List proof}) r => (deck: Uint8List.fromList(r.deck), proof: Uint8List.fromList(r.proof)),
        _ => a,
      };
    }
    madeHere++;
    return job.run(inner);
  }

  @override
  Uint8List initialDeck(Uint8List joint) => _answer(InitialDeckJob(joint)) as Uint8List;

  @override
  ({Uint8List deck, Uint8List proof}) shuffle(Uint8List joint, Uint8List deck, Uint8List seed) =>
      _answer(ShuffleJob(joint, deck, seed)) as ({Uint8List deck, Uint8List proof});

  @override
  bool verifyShuffle(Uint8List joint, Uint8List before, Uint8List after, Uint8List proof) =>
      _answer(VerifyShuffleJob(joint, before, after, proof)) as bool;

  @override
  Uint8List revealTokens(Uint8List secret, Uint8List cards, Uint8List seed) =>
      _answer(RevealTokensJob(secret, cards, seed)) as Uint8List;

  @override
  bool verifyTokens(Uint8List pk, Uint8List cards, Uint8List tokens) => _answer(VerifyTokensJob(pk, cards, tokens)) as bool;

  // The rest are quick, and made here.

  @override
  Uint8List keygen(Uint8List secret) => inner.keygen(secret);
  @override
  Uint8List keyProof(Uint8List secret, Uint8List name, Uint8List seed) => inner.keyProof(secret, name, seed);
  @override
  bool verifyKey(Uint8List pk, Uint8List name, Uint8List proof) => inner.verifyKey(pk, name, proof);
  @override
  Uint8List aggregate(List<Uint8List> pks) => inner.aggregate(pks);
  @override
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed) => inner.revealToken(secret, masked, seed);
  @override
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token) => inner.verifyToken(pk, masked, token);
  @override
  Uint8List split(Uint8List secret, Uint8List seed, {int shares = 2}) => inner.split(secret, seed, shares: shares);
  @override
  Uint8List shareBytes(Uint8List secret, {required int n, required int t, required Uint8List seed}) =>
      inner.shareBytes(secret, n: n, t: t, seed: seed);
  @override
  int bytesLagrange(List<int> have, int index, {int at = 0}) => inner.bytesLagrange(have, index, at: at);
  @override
  Uint8List bytesScale(Uint8List share, int by) => inner.bytesScale(share, by);
  @override
  Uint8List bytesSum(List<Uint8List> parts) => inner.bytesSum(parts);
  @override
  Uint8List splitThreshold(Uint8List secret, {required int n, required int t, required Uint8List seed}) =>
      inner.splitThreshold(secret, n: n, t: t, seed: seed);
  @override
  Uint8List lagrange(List<int> have, int index, {int at = 0}) => inner.lagrange(have, index, at: at);
  @override
  Uint8List scalarMul(Uint8List a, Uint8List b) => inner.scalarMul(a, b);
  @override
  Uint8List scalarSum(List<Uint8List> parts) => inner.scalarSum(parts);
  @override
  Uint8List pointScale(Uint8List point, Uint8List scalar) => inner.pointScale(point, scalar);
  @override
  Uint8List shareKey(Uint8List share) => inner.shareKey(share);
  @override
  Uint8List openShared(Uint8List sealed, List<Uint8List> parts) => inner.openShared(sealed, parts);
  @override
  Uint8List shareToken(Uint8List share, Uint8List masked, Uint8List seed) => inner.shareToken(share, masked, seed);
  @override
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked) => inner.unmask(pks, tokens, masked);
  @override
  Uint8List seal(Uint8List secret, Uint8List pkTo, Uint8List masked, Uint8List seed) => inner.seal(secret, pkTo, masked, seed);
  @override
  bool verifySeal(Uint8List pkOwner, Uint8List pkTo, Uint8List masked, Uint8List sealed) =>
      inner.verifySeal(pkOwner, pkTo, masked, sealed);
  @override
  Uint8List open(Uint8List secret, Uint8List sealed) => inner.open(secret, sealed);
  @override
  Uint8List sharedSecret(Uint8List secret, Uint8List pk) => inner.sharedSecret(secret, pk);
}

/// Somewhere to make [DealJob]s other than here.
///
/// Answers come back through callbacks rather than a future, so that
/// the simulator's worker can answer on its virtual clock without the
/// event loop turning ([DealWorker] implementations in packages/table).
abstract class DealWorker {
  /// The platform's: a Web Worker running `deal_worker.js` beside the
  /// app in the browser, an isolate with the cdylib open on the VM.
  /// Ready at once; jobs sent before the worker has its primitives
  /// loaded wait for them, and fail if they never load.
  static DealWorker start({String? libraryPath}) => platform.start(libraryPath: libraryPath);

  /// Makes [job], then calls [done] with its answer — or [failed],
  /// once, if it cannot be made there at all.
  void run(DealJob job, {required void Function(Object answer) done, required void Function(Object error) failed});

  void close();
}
