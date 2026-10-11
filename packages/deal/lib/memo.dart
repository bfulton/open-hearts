/// The deal's cryptography, remembered.
///
/// Every operation is a function of its bytes — the randomness comes
/// in as a seed — so the same call gives the same answer. A table
/// checks the same proofs over and over: every person and every juror
/// checks each shuffle, each token and each seal, and a verifier checks
/// them all again at the end; and a tool that runs one game hundreds of
/// times with one thing different (packages/table, tool/explore.dart)
/// makes most of the same calls every time. This answers those from
/// memory and asks the real library only about what is new. Nothing
/// here is for a real table: it is for tests and the simulator's
/// tools, and not exported by deal.dart.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'deal.dart';

/// The deal's cryptography as a test takes it: the real library, every
/// answer remembered — for as long as the test file runs, and, [kept],
/// on disk beside the library that gave it, for the next file and the
/// next run.
///
/// A sealed table is the same proofs checked over and over — every
/// person and every juror checks each shuffle, each token and each
/// seal, and the verifier checks them all again at the end — and the
/// tests of one file play the same seeds into one departure after
/// another. Each is asked of the library once. Nothing a test checks is
/// lost: an answer is the library's, for exactly those bytes, and a
/// proof changed by a byte is new bytes, asked afresh. What is kept is
/// kept under a hash of the library's own file, so a library built
/// again from changed sources answers everything afresh.
///
/// [kept] is for a table on the simulator's clock, where how long the
/// library takes is no part of what is tested. A test on the wall clock
/// (service/test) keeps answers in memory only, so each device's own
/// shuffle still costs what it costs. `OH_DEAL_MEMO=off` keeps nothing
/// on disk anywhere.
Future<DealCrypto> rememberedCrypto({bool kept = true}) async {
  final real = _real ??= await DealCrypto.load();
  if (!kept) return _inMemory ??= MemoCrypto(real);
  return _onDisk ??= MemoCrypto(real, keep: _keepingDir());
}

DealCrypto? _real;
MemoCrypto? _inMemory;
MemoCrypto? _onDisk;

/// Where answers are kept: `target/memo/<the library's hash>` beside the
/// library this process loads (crypto/deal), or nowhere.
String? _keepingDir() {
  if (Platform.environment['OH_DEAL_MEMO'] == 'off') return null;
  for (final base in [Directory.current.path, '${Directory.current.path}/..', '${Directory.current.path}/../..']) {
    for (final name in ['libdeal.so', 'libdeal.dylib', 'deal.dll']) {
      final lib = File('$base/crypto/deal/target/release/$name');
      if (!lib.existsSync()) continue;
      final hash = sha256.convert(lib.readAsBytesSync()).toString().substring(0, 16);
      final memo = Directory('${lib.parent.parent.path}/memo');
      // What an older build of the library said is no use to this one.
      try {
        for (final old in memo.listSync().whereType<Directory>()) {
          if (!old.path.endsWith('/$hash')) old.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // Not there yet, or another file's isolate got to it first.
      }
      return '${memo.path}/$hash';
    }
  }
  return null;
}

class MemoCrypto implements DealCrypto {
  /// The library [_real], remembered in memory — and in `keep`, a
  /// directory, when there is one.
  MemoCrypto(this._real, {this._keep});
  final DealCrypto _real;
  final String? _keep;
  final Map<String, Object?> _memo = {};

  /// Answers served from memory, read from disk, and asked of the
  /// library.
  int hits = 0;
  int read = 0;
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
    final file = _keep == null ? null : _fileFor(k);
    if (file != null) {
      final (found, kept) = _readKept(file);
      if (found) {
        read++;
        _memo[k] = kept;
        return _copy(kept) as T;
      }
    }
    misses++;
    final v = compute();
    _memo[k] = _copy(v);
    if (file != null) _writeKept(file, v);
    return v;
  }

  File _fileFor(String key) {
    final h = sha256.convert(utf8.encode(key)).toString();
    return File('$_keep/${h.substring(0, 2)}/${h.substring(2)}');
  }

  // On disk, a tag and the bytes: 0 null, 1 a bool, 2 an int, 3 bytes,
  // 4 a deck and its proof.
  static (bool, Object?) _readKept(File f) {
    final Uint8List b;
    try {
      b = f.readAsBytesSync();
    } on FileSystemException {
      return (false, null);
    }
    if (b.isEmpty) return (false, null);
    final rest = Uint8List.sublistView(b, 1);
    switch (b[0]) {
      case 0:
        return (true, null);
      case 1 when rest.length == 1:
        return (true, rest[0] == 1);
      case 2 when rest.length == 8:
        return (true, ByteData.sublistView(rest).getInt64(0));
      case 3:
        return (true, Uint8List.fromList(rest));
      case 4 when rest.length >= 4:
        final n = ByteData.sublistView(rest).getUint32(0);
        if (rest.length < 4 + n) return (false, null);
        return (true, (deck: Uint8List.fromList(rest.sublist(4, 4 + n)), proof: Uint8List.fromList(rest.sublist(4 + n))));
    }
    return (false, null);
  }

  static final _tmp = Random();

  // Written whole under another name and moved into place, so a reader
  // in another isolate or process sees all of an answer or none of it.
  static void _writeKept(File f, Object? v) {
    final b = BytesBuilder(copy: false);
    switch (v) {
      case null:
        b.addByte(0);
      case bool x:
        b
          ..addByte(1)
          ..addByte(x ? 1 : 0);
      case int x:
        b
          ..addByte(2)
          ..add((ByteData(8)..setInt64(0, x)).buffer.asUint8List());
      case Uint8List x:
        b
          ..addByte(3)
          ..add(x);
      case ({Uint8List deck, Uint8List proof}) r:
        b
          ..addByte(4)
          ..add((ByteData(4)..setUint32(0, r.deck.length)).buffer.asUint8List())
          ..add(r.deck)
          ..add(r.proof);
      default:
        return;
    }
    try {
      f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.$pid.${_tmp.nextInt(1 << 32)}');
      tmp.writeAsBytesSync(b.takeBytes());
      tmp.renameSync(f.path);
    } on FileSystemException {
      // Nothing kept is nothing lost.
    }
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
