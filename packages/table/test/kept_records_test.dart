/// Games kept by an older library still read, to the end, and a copy
/// bent anywhere the deal's cryptography vouches for does not.
///
/// test/fixtures/ holds two sealed games as the library built on
/// arkworks 0.3 wrote them (tool/kept_records.dart, run once): four
/// people to the end of the game, and three people and a bot where a
/// person leaves mid-hand and the hand is finished from escrow. Records
/// like them are kept for anyone to look at (game_record.dart), and the
/// review page checks them in the browser exactly as here.
///
/// Asked of the library itself, never of remembered answers
/// (package:deal/memo.dart): `OH_DEAL_MEMO` does not reach this file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

import '../tool/kept_records.dart' show threeAndALeaver, threeNames;

Map<String, Object?> fixture(String name) =>
    jsonDecode(utf8.decode(gzip.decode(File('test/fixtures/$name.json.gz').readAsBytesSync()))) as Map<String, Object?>;

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  Verification check(Map<String, Object?> json, {bool signatures = true}) {
    final r = GameRecord.parse(json, verifySignatures: signatures);
    expect(r, isNotNull, reason: 'the record reads');
    return verifyRecord(r!.spec, r.record, juries: r.juries, crypto: crypto, releases: r.releases);
  }

  /// [json] with the first event of [kind] (and [round], for the deal's)
  /// that has [field] changed by [bend], its id worked out again so that
  /// only its signature — not checked here — is out of date.
  Map<String, Object?> bent(Map<String, Object?> json, String kind, String field, Object? Function(Object?) bend, {int? round}) {
    final copy = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
    for (final d in copy['record'] as List) {
      final e = (d as Map)['event'] as Map;
      final body = e['body'] as Map;
      if (e['kind'] != kind || (round != null && body['round'] != round) || !body.containsKey(field)) continue;
      body[field] = bend(body[field]);
      e['id'] = TableEvent.idFor(
          table: e['table'] as String,
          author: e['author'] as String,
          kind: EventKind.values.byName(kind),
          body: Map<String, Object?>.from(body));
      return copy;
    }
    throw StateError('no $kind event with $field');
  }

  /// A base64 field with one bit flipped at [at] (from the end, if
  /// negative).
  Object? flip(Object? b64, int at) {
    final b = Uint8List.fromList(base64.decode(b64 as String));
    b[at < 0 ? b.length + at : at] ^= 1;
    return base64.encode(b);
  }

  // The four people's keys are real ones and their signatures are
  // checked; the game with a jury was played on the simulator, whose
  // jurors sign as only a running simulator accepts, so its signatures
  // are left unchecked: they are not what this is about.
  for (final (name, signatures) in [('sealed_four', true), ('sealed_three_leave', false)]) {
    test('$name, kept by the older library, verifies to its end', () {
      final v = check(fixture(name), signatures: signatures);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.complete, isTrue);
    });
  }

  test('the escrow\'s game, played again today, is the same record to the byte', () {
    // Every key, shuffle, token, seal, share and proof in it made again
    // by this library from the same seeds, and the record they make the
    // one the older library kept.
    final t = threeAndALeaver(crypto);
    final again = jsonEncode(GameRecord.of(t.people.first.client, names: threeNames).toJson());
    t.stop();
    expect(again, utf8.decode(gzip.decode(File('test/fixtures/sealed_three_leave.json.gz').readAsBytesSync())));
  });

  test('the escrow\'s game carries its jury and its released pieces', () {
    final json = fixture('sealed_three_leave');
    expect(json['juries'], isNotEmpty);
    expect(json['releases'], isNotEmpty);
  });

  group('bent where the deal vouches for it, it does not verify', () {
    late Map<String, Object?> four;
    setUpAll(() => four = fixture('sealed_four'));

    test('unbent, with its signatures not checked, it does', () {
      final v = check(four, signatures: false);
      expect(v.ok, isTrue, reason: v.reason);
    });

    final cases = <String, Map<String, Object?> Function(Map<String, Object?>)>{
      'a key\'s proof': (j) => bent(j, 'deal', 'proof', (p) => flip(p, 3), round: 0),
      'a key': (j) => bent(j, 'deal', 'pk', (p) => flip(p, 0), round: 0),
      'a shuffle\'s argument, early': (j) => bent(j, 'deal', 'proof', (p) => flip(p, 100), round: 1),
      'a shuffle\'s argument, late': (j) => bent(j, 'deal', 'proof', (p) => flip(p, -40), round: 1),
      'a shuffled deck': (j) => bent(j, 'deal', 'deck', (p) => flip(p, 1000), round: 1),
      'a batch of tokens': (j) => bent(j, 'deal', 'tokens', (p) => flip(p, 40), round: 2),
      'the batch\'s argument': (j) => bent(j, 'deal', 'tokens', (p) => flip(p, -10), round: 2),
      'a declared token': (j) => bent(j, 'deal', 'token', (p) => flip(p, 2), round: 3),
      'a played token\'s proof': (j) => bent(j, 'play', 'token', (p) => flip(p, 70)),
      'a sealed pass': (j) => bent(j, 'pass', 'sealed', (l) => [flip((l as List).first, 5), ...l.skip(1)]),
      // (The reveal proofs a pass carries beside its seals are the
      // receiver's to play the cards with, and are checked when it does.)
      'a seal\'s argument': (j) => bent(j, 'pass', 'sealed', (l) => [flip((l as List).first, -10), ...l.skip(1)]),
      'an audited secret': (j) => bent(j, 'deal', 'secret', (p) => flip(p, 9), round: 4),
    };
    for (final c in cases.entries) {
      test(c.key, () {
        final v = check(c.value(four), signatures: false);
        expect(v.ok, isFalse, reason: 'bent ${c.key}, and still it verified');
      });
    }
  });

  group('the escrow\'s game, bent where its shares are vouched for, does not verify', () {
    late Map<String, Object?> three;
    setUpAll(() => three = fixture('sealed_three_leave'));

    final cases = <String, Map<String, Object?> Function(Map<String, Object?>)>{
      'a share\'s key': (j) => bent(j, 'deal', 'shareKeys', (l) => [flip((l as List).first, 4), ...l.skip(1)], round: 0),
      'the leaver\'s played token': (j) => bent(j, 'play', 'token', (p) => flip(p, 1)),
    };
    for (final c in cases.entries) {
      test(c.key, () {
        final v = check(c.value(three), signatures: false);
        expect(v.ok, isFalse, reason: 'bent ${c.key}, and still it verified');
      });
    }
  });
}
