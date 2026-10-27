/// Games kept still read, to the end, and a copy bent anywhere the deal's
/// cryptography or the house vouches for does not: those kept at a
/// refereed table (record.dart), and those kept before the referee — and
/// by an older library (legacy/v2_record.dart).
///
/// test/fixtures/ holds one game of the referee's (refereed_four, made
/// with tool/game_fixture.dart: four people with real keys, the browser
/// rig's house, to the end of a game to fifty), and two sealed games as
/// the library built on arkworks 0.3 wrote them (once, with a tool since
/// gone): four people to the end of the game, and three people and a bot
/// where a person leaves mid-hand and the hand is finished from escrow.
/// Records like them are kept for anyone to look at, and the review page
/// checks them in the browser exactly as here.
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

Map<String, Object?> fixture(String name) =>
    jsonDecode(utf8.decode(gzip.decode(File('test/fixtures/$name.json.gz').readAsBytesSync()))) as Map<String, Object?>;

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  Verification check(Map<String, Object?> json, {bool signatures = true}) {
    final r = GameRecordV2.parse(json, verifySignatures: signatures);
    expect(r, isNotNull, reason: 'the record reads');
    return verifyRecordV2(r!.spec, r.record, juries: r.juries, crypto: crypto, releases: r.releases);
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
      e['id'] = V2Event.idFor(
          table: e['table'] as String,
          author: e['author'] as String,
          kind: V2Kind.values.byName(kind),
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

  group('a game kept at a refereed table', () {
    // The browser rig's house, which played the game and signed for its
    // log: BIP-340's third published pair (tool/game_fixture.dart).
    const house = 'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8';
    late Map<String, Object?> refereed;
    setUpAll(() => refereed = fixture('refereed_four'));

    RecordVerdict verified(Map<String, Object?> json, {PublicKey by = house, bool signatures = true}) {
      final r = GameRecord.parse(json, verifySignatures: signatures);
      expect(r, isNotNull, reason: 'the record reads');
      return verifyRecord(r!, crypto: crypto, house: by);
    }

    test('verifies to its end, and the house\'s word on it with it', () {
      final v = verified(refereed);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.state, TableState.finished);
      expect(v.vouched, isTrue);
      expect(v.totals, [5, 34, 63, 28]);
      expect(v.winners, [0]);
    });

    test('naming another house, it is no game of this build\'s', () {
      expect(verified(refereed, by: 'ab' * 32).ok, isFalse);
    });

    /// A copy of the game with [change] made to its log.
    Map<String, Object?> copy(void Function(List<Map<String, Object?>> log) change) {
      final json = jsonDecode(jsonEncode(refereed)) as Map<String, Object?>;
      change((json['log'] as List).cast<Map<String, Object?>>());
      return json;
    }

    /// The [nth] event of [kind] in [log].
    Map<String, Object?> eventOf(List<Map<String, Object?>> log, String kind, [int nth = 0]) =>
        [for (final e in log) if ((e['e'] as Map?)?['kind'] == kind) e['e'] as Map<String, Object?>][nth];

    /// [e] with its id worked out again for what it now says, as the
    /// table works one out (events.dart): only its signature, which
    /// nobody but its author can make again, still gives it away.
    // Every map's keys in order at every depth, as events.dart hashes them.
    Object? inOrder(Object? json) => json is List
        ? [for (final e in json) inOrder(e)]
        : json is Map
            ? {for (final k in [for (final k in json.keys) k as String]..sort()) k: inOrder(json[k])}
            : json;
    void reId(Map<String, Object?> e) {
      e['id'] = digestOf(Uint8List.fromList(utf8.encode(jsonEncode([e['table'], e['author'], e['kind'], inOrder(e['body'])]))));
    }

    test('its ids made again here are its own: what the bends below rely on', () {
      final v = verified(copy((log) {
        for (final e in log) {
          if (e['e'] case final Map<String, Object?> ev) reId(ev);
        }
      }));
      expect(v.ok, isTrue, reason: v.reason);
    });

    final bends = <String, ({void Function(List<Map<String, Object?>> log) change, bool signatures})>{
      // Signed as they were: a log put together differently from the one
      // the referee kept.
      'two moves in another order': (
        change: (log) {
          final at = log.indexWhere((e) => (e['e'] as Map?)?['kind'] == 'play');
          final e = log[at]['e'];
          log[at]['e'] = log[at + 1]['e'];
          log[at + 1]['e'] = e;
        },
        signatures: true,
      ),
      'a move left out, the rest numbered again': (
        change: (log) {
          log.removeAt(log.indexWhere((e) => (e['e'] as Map?)?['kind'] == 'play'));
          for (final (n, e) in log.indexed) {
            e['n'] = n;
          }
        },
        signatures: true,
      ),
      'a move\'s time moved on': (
        change: (log) {
          final e = log.firstWhere((e) => (e['e'] as Map?)?['kind'] == 'play');
          e['t'] = (e['t'] as int) + 1;
        },
        signatures: true,
      ),
      'a card played changed, its signature that of the card that was': (
        change: (log) {
          final e = eventOf(log, 'play', 5);
          (e['body'] as Map)['card'] = (e['body'] as Map)['card'] == '2C' ? '3C' : '2C';
          reId(e);
        },
        signatures: true,
      ),
      // Signatures not checked: what the house's word and the deal's
      // proofs vouch for, each on its own.
      'a card played changed': (
        change: (log) {
          final e = eventOf(log, 'play', 5);
          (e['body'] as Map)['card'] = (e['body'] as Map)['card'] == '2C' ? '3C' : '2C';
          reId(e);
        },
        signatures: false,
      ),
      'a shuffle\'s argument': (
        change: (log) {
          final e = eventOf(log, 'deal', 4);
          final body = e['body'] as Map;
          final key = body.containsKey('proof') ? 'proof' : body.keys.firstWhere((k) => body[k] is String && (body[k] as String).length > 100);
          body[key] = flip(body[key], 100);
          reId(e);
        },
        signatures: false,
      ),
      'the house\'s totals': (
        change: (log) {
          final e = eventOf(log, 'result');
          final totals = List.of((e['body'] as Map)['totals'] as List)..[0] = 0;
          (e['body'] as Map)['totals'] = totals;
          reId(e);
        },
        signatures: false,
      ),
    };
    for (final b in bends.entries) {
      test(b.key, () {
        final v = verified(copy(b.value.change), signatures: b.value.signatures);
        expect(v.ok, isFalse, reason: 'bent: ${b.key}, and still it verified');
      });
    }
  });
}
