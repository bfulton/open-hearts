/// The deal over FFI held to the golden vectors: every call of the deal
/// on fixed seeds, with what the library built on arkworks 0.3
/// answered, byte for byte — keys, proofs, the deck, shuffles and their
/// arguments, tokens, seals, shares, and the same calls with an
/// argument bent or oddly encoded (crypto/deal/tests/golden.rs writes
/// and replays the same file natively; e2e/deal_golden.test.mjs replays
/// it in the browser's wasm).
///
/// Asked of the library itself, never of remembered answers
/// (memo.dart): what is tested is what the library says now.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:test/test.dart';

Uint8List unhex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

List<Uint8List> chunks(Uint8List b, int n) => [for (var i = 0; i < b.length; i += n) Uint8List.sublistView(b, i, i + n)];

void main() {
  late DealCrypto d;
  late Map<String, Uint8List> values;
  late List<Map<String, Object?>> calls;
  setUpAll(() async {
    d = await DealCrypto.load();
    final v = jsonDecode(File('../../crypto/deal/tests/golden/vectors.json').readAsStringSync()) as Map<String, Object?>;
    values = {for (final e in (v['values'] as Map<String, Object?>).entries) e.key: unhex(e.value as String)};
    calls = [for (final c in v['calls'] as List) Map<String, Object?>.from(c as Map)];
  });

  /// What a call answers, as the flat interface would return it: the
  /// return value, and the bytes written. A binding that throws is the
  /// interface's -1.
  ({int ret, Uint8List? out}) run(String op, List<Uint8List> a, List<int> n) {
    ({int ret, Uint8List? out}) w(Uint8List Function() f) {
      try {
        final out = f();
        return (ret: out.length, out: out);
      } on StateError {
        return (ret: -1, out: null);
      }
    }

    ({int ret, Uint8List? out}) b(bool ok) => (ret: ok ? 1 : 0, out: null);
    return switch (op) {
      'keygen' => w(() => d.keygen(a[0])),
      'key_proof' => w(() => d.keyProof(a[0], a[1], a[2])),
      'verify_key' => b(d.verifyKey(a[0], a[1], a[2])),
      'aggregate' => w(() => d.aggregate(chunks(a[0], pointBytes))),
      'initial_deck' => w(() => d.initialDeck(a[0])),
      'shuffle' => () {
          try {
            final s = d.shuffle(a[0], a[1], a[2]);
            return (ret: s.proof.length, out: Uint8List.fromList([...s.deck, ...s.proof]));
          } on StateError {
            return (ret: -1, out: null);
          }
        }(),
      'verify_shuffle' => b(d.verifyShuffle(a[0], a[1], a[2], a[3])),
      'reveal_token' => w(() => d.revealToken(a[0], a[1], a[2])),
      'verify_token' => b(d.verifyToken(a[0], a[1], a[2])),
      'reveal_tokens' => w(() => d.revealTokens(a[0], a[1], a[2])),
      'verify_tokens' => b(d.verifyTokens(a[0], a[1], a[2])),
      'split' => w(() => d.split(a[0], a[1], shares: n[0])),
      'share_bytes' => w(() => d.shareBytes(a[0], n: n[0], t: n[1], seed: a[1])),
      'bytes_lagrange' => () {
          try {
            return (ret: d.bytesLagrange(a[0], n[0], at: n[1]), out: null);
          } on StateError {
            return (ret: -1, out: null);
          }
        }(),
      'bytes_scale' => w(() => d.bytesScale(a[0], n[0])),
      'bytes_sum' => w(() => d.bytesSum(chunks(a[0], n[0]))),
      'split_threshold' => w(() => d.splitThreshold(a[0], n: n[0], t: n[1], seed: a[1])),
      'lagrange' => w(() => d.lagrange(a[0], n[0], at: n[1])),
      'scalar_mul' => w(() => d.scalarMul(a[0], a[1])),
      'scalar_sum' => w(() => d.scalarSum(chunks(a[0], scalarBytes))),
      'point_scale' => w(() => d.pointScale(a[0], a[1])),
      'share_key' => w(() => d.shareKey(a[0])),
      'share_token' => w(() => d.shareToken(a[0], a[1], a[2])),
      'open_shared' => w(() => d.openShared(a[0], chunks(a[1], pointBytes))),
      'unmask' => (ret: d.unmask(chunks(a[0], pointBytes), chunks(a[1], pointBytes), a[2]) ?? -1, out: null),
      'seal' => w(() => d.seal(a[0], a[1], a[2], a[3])),
      'verify_seal' => b(d.verifySeal(a[0], a[1], a[2], a[3])),
      'open' => w(() => d.open(a[0], a[1])),
      'shared_secret' => w(() => d.sharedSecret(a[0], a[1])),
      _ => throw ArgumentError('no such op $op'),
    };
  }

  test('the library answers every golden call as the library built on arkworks 0.3 did', () {
    final wrong = <String>[];
    for (var k = 0; k < calls.length; k++) {
      final c = calls[k];
      final bytes = <Uint8List>[];
      final ints = <int>[];
      for (final arg in c['args'] as List) {
        if (arg is int) {
          ints.add(arg);
          continue;
        }
        final [name, ...flip] = (arg as String).split('^');
        final v = Uint8List.fromList(values[name] ?? (throw StateError('no value $name')));
        if (flip.isNotEmpty) v[int.parse(flip.single)] ^= 1;
        bytes.add(v);
      }
      final got = run(c['op'] as String, bytes, ints);
      if (got.ret != c['ret']) {
        wrong.add('call $k ${c['op']} ${c['args']}: returned ${got.ret}, was ${c['ret']}');
      } else if (c['out'] case final String name when got.out == null || !_same(got.out!, values[name]!)) {
        wrong.add('call $k ${c['op']} ${c['args']}: wrote other bytes than $name');
      }
    }
    expect(wrong, isEmpty, reason: '${wrong.length} of ${calls.length} calls answer differently');
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
