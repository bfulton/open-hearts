/// The deal's cryptography, remembered across runs of the same game.
///
/// Every operation is a function of its bytes — the randomness comes
/// in as a seed — so the same call gives the same answer, and a tool
/// that runs one game hundreds of times with one thing different
/// (tool/explore.dart) makes most of the same calls every time. This
/// answers those from memory and asks the real library only about
/// what is new. Nothing here is for a real table.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:deal/deal.dart';

class MemoCrypto implements DealCrypto {
  MemoCrypto(this._real);
  final DealCrypto _real;
  final Map<String, Object?> _memo = {};

  /// Answers served from memory, and asked of the library.
  int hits = 0;
  int misses = 0;

  String _key(String op, List<Object?> args) {
    final b = StringBuffer(op);
    for (final a in args) {
      b.write('|');
      if (a is Uint8List) {
        b.write(base64.encode(a));
      } else if (a is List<Uint8List>) {
        b.write(a.map(base64.encode).join(','));
      } else {
        b.write(a);
      }
    }
    return b.toString();
  }

  T _once<T>(String op, List<Object?> args, T Function() compute) {
    final k = _key(op, args);
    if (_memo.containsKey(k)) {
      hits++;
      return _copy(_memo[k]) as T;
    }
    misses++;
    final v = compute();
    _memo[k] = _copy(v);
    return v;
  }

  // Handed out as copies, and kept as copies: a caller that writes
  // into what it was given must not write into the next run's answer.
  static Object? _copy(Object? v) => switch (v) {
        Uint8List b => Uint8List.fromList(b),
        ({Uint8List deck, Uint8List proof}) r => (deck: Uint8List.fromList(r.deck), proof: Uint8List.fromList(r.proof)),
        _ => v,
      };

  @override
  Uint8List keygen(Uint8List secret) => _once('keygen', [secret], () => _real.keygen(secret));
  @override
  Uint8List keyProof(Uint8List secret, Uint8List name, Uint8List seed) =>
      _once('keyProof', [secret, name, seed], () => _real.keyProof(secret, name, seed));
  @override
  bool verifyKey(Uint8List pk, Uint8List name, Uint8List proof) =>
      _once('verifyKey', [pk, name, proof], () => _real.verifyKey(pk, name, proof));
  @override
  Uint8List aggregate(List<Uint8List> pks) => _once('aggregate', [pks], () => _real.aggregate(pks));
  @override
  Uint8List initialDeck(Uint8List joint) => _once('initialDeck', [joint], () => _real.initialDeck(joint));
  @override
  ({Uint8List deck, Uint8List proof}) shuffle(Uint8List joint, Uint8List deck, Uint8List seed) =>
      _once('shuffle', [joint, deck, seed], () => _real.shuffle(joint, deck, seed));
  @override
  bool verifyShuffle(Uint8List joint, Uint8List before, Uint8List after, Uint8List proof) =>
      _once('verifyShuffle', [joint, before, after, proof], () => _real.verifyShuffle(joint, before, after, proof));
  @override
  Uint8List revealToken(Uint8List secret, Uint8List masked, Uint8List seed) =>
      _once('revealToken', [secret, masked, seed], () => _real.revealToken(secret, masked, seed));
  @override
  bool verifyToken(Uint8List pk, Uint8List masked, Uint8List token) =>
      _once('verifyToken', [pk, masked, token], () => _real.verifyToken(pk, masked, token));
  @override
  Uint8List revealTokens(Uint8List secret, Uint8List cards, Uint8List seed) =>
      _once('revealTokens', [secret, cards, seed], () => _real.revealTokens(secret, cards, seed));
  @override
  bool verifyTokens(Uint8List pk, Uint8List cards, Uint8List tokens) =>
      _once('verifyTokens', [pk, cards, tokens], () => _real.verifyTokens(pk, cards, tokens));
  @override
  Uint8List split(Uint8List secret, Uint8List seed, {int shares = 2}) =>
      _once('split', [secret, seed, shares], () => _real.split(secret, seed, shares: shares));
  @override
  Uint8List shareBytes(Uint8List secret, {required int n, required int t, required Uint8List seed}) =>
      _once('shareBytes', [secret, n, t, seed], () => _real.shareBytes(secret, n: n, t: t, seed: seed));
  @override
  int bytesLagrange(List<int> have, int index, {int at = 0}) =>
      _once('bytesLagrange', [have.join(','), index, at], () => _real.bytesLagrange(have, index, at: at));
  @override
  Uint8List bytesScale(Uint8List share, int by) => _once('bytesScale', [share, by], () => _real.bytesScale(share, by));
  @override
  Uint8List bytesSum(List<Uint8List> parts) => _once('bytesSum', [parts], () => _real.bytesSum(parts));
  @override
  Uint8List splitThreshold(Uint8List secret, {required int n, required int t, required Uint8List seed}) =>
      _once('splitThreshold', [secret, n, t, seed], () => _real.splitThreshold(secret, n: n, t: t, seed: seed));
  @override
  Uint8List lagrange(List<int> have, int index, {int at = 0}) =>
      _once('lagrange', [have.join(','), index, at], () => _real.lagrange(have, index, at: at));
  @override
  Uint8List scalarMul(Uint8List a, Uint8List b) => _once('scalarMul', [a, b], () => _real.scalarMul(a, b));
  @override
  Uint8List scalarSum(List<Uint8List> parts) => _once('scalarSum', [parts], () => _real.scalarSum(parts));
  @override
  Uint8List pointScale(Uint8List point, Uint8List scalar) =>
      _once('pointScale', [point, scalar], () => _real.pointScale(point, scalar));
  @override
  Uint8List shareKey(Uint8List share) => _once('shareKey', [share], () => _real.shareKey(share));
  @override
  Uint8List openShared(Uint8List sealed, List<Uint8List> parts) =>
      _once('openShared', [sealed, parts], () => _real.openShared(sealed, parts));
  @override
  Uint8List shareToken(Uint8List share, Uint8List masked, Uint8List seed) =>
      _once('shareToken', [share, masked, seed], () => _real.shareToken(share, masked, seed));
  @override
  int? unmask(List<Uint8List> pks, List<Uint8List> tokens, Uint8List masked) =>
      _once('unmask', [pks, tokens, masked], () => _real.unmask(pks, tokens, masked));
  @override
  Uint8List seal(Uint8List secret, Uint8List pkTo, Uint8List masked, Uint8List seed) =>
      _once('seal', [secret, pkTo, masked, seed], () => _real.seal(secret, pkTo, masked, seed));
  @override
  bool verifySeal(Uint8List pkOwner, Uint8List pkTo, Uint8List masked, Uint8List sealed) =>
      _once('verifySeal', [pkOwner, pkTo, masked, sealed], () => _real.verifySeal(pkOwner, pkTo, masked, sealed));
  @override
  Uint8List open(Uint8List secret, Uint8List sealed) => _once('open', [secret, sealed], () => _real.open(secret, sealed));
  @override
  Uint8List sharedSecret(Uint8List secret, Uint8List pk) =>
      _once('sharedSecret', [secret, pk], () => _real.sharedSecret(secret, pk));
}
