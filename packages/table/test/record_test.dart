/// A kept game (record.dart): the spec and the referee's log, played
/// again by anyone, and checked against the house's word on how it came
/// out — every entry of it, so that a log bent anywhere does not check.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// [record]'s JSON, through text, as it is stored and fetched.
Map<String, Object?> stored(GameRecord record) => jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>;

void main() {
  late DealCrypto crypto;
  setUpAll(() async {
    crypto = await rememberedCrypto();
    await installNativeSchnorr();
  });

  group('a sealed game, kept', () {
    late SimTable t;
    late GameRecord kept;
    setUpAll(() {
      t = SimTable(humans: 2, seed: 101, crypto: crypto);
      t.start();
      expect(t.run(), isTrue);
      kept = GameRecord.of(t.clients.first, names: const {0: 'Ada', 1: 'Bao'});
      t.close();
    });

    test('plays again to the same end, the house\'s word on it in the log', () {
      final replay = TableReplay();
      final v = verifyRecord(kept, crypto: crypto, house: t.houseSigner.publicKey, replay: replay);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.state, TableState.finished);
      expect(v.vouched, isTrue);
      final c = t.clients.first;
      expect(v.totals, c.game.totals);
      expect(v.winners, c.game.winners);
      // Shown hand by hand: every card played, and every hand as dealt
      // once its audit opened it.
      expect(replay.hands, hasLength(c.game.handNumber + 1));
      for (final h in replay.hands) {
        expect(h.plays, hasLength(52), reason: 'hand ${h.number}');
        expect(h.dealt, isNotNull, reason: 'hand ${h.number}, opened by its audit');
        expect(h.totals, isNotEmpty);
      }
      expect(replay.hands.last.totals, c.game.totals);
    });

    test('reads back from what is stored, names and all', () {
      final back = GameRecord.parse(stored(kept), verifySignatures: false)!;
      expect(back.log, hasLength(kept.log.length));
      expect(back.names, {0: 'Ada', 1: 'Bao'});
      final v = verifyRecord(back, crypto: crypto, house: t.houseSigner.publicKey);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.vouched, isTrue);
    });

    test('reads a name as it may be shown: nothing in it that turns text round, and no longer than a kept name', () {
      final m = stored(kept)..['names'] = {'0': '\u202enimda\u202c', '1': '😀' * 50};
      expect(GameRecord.parse(m, verifySignatures: false)!.names, {0: 'nimda', 1: '😀' * 40});
    });

    test('is not a game of another house\'s, nor checked without the deal', () {
      expect(verifyRecord(kept, crypto: crypto, house: FakeSigner('another house').publicKey).ok, isFalse);
      expect(verifyRecord(kept).ok, isFalse);
    });

    test('kept before the end is a game under way; kept before the house said its word, it does not check', () {
      final under = GameRecord(spec: kept.spec, log: kept.log.take(kept.log.length ~/ 2).toList());
      expect(verifyRecord(under, crypto: crypto).ok, isFalse, reason: 'a kept game is over');
      final u = verifyRecord(under, crypto: crypto, allowUnfinished: true);
      expect(u.ok, isTrue, reason: u.reason);
      expect(u.complete, isFalse);
      expect(u.state, TableState.playing);
      final endN = kept.log.indexWhere((e) => e.event?.kind == EventKind.result);
      final unsaid = GameRecord(spec: kept.spec, log: kept.log.take(endN).toList());
      final w = verifyRecord(unsaid, crypto: crypto);
      expect(w.ok, isFalse);
      expect(w.reason, contains('house'));
    });
  });

  test('an unsealed game has no house to vouch for it, and checks as played', () {
    final t = SimTable(humans: 2, seed: 102);
    t.start();
    expect(t.run(), isTrue);
    final v = verifyRecord(GameRecord.parse(stored(GameRecord.of(t.clients.first)), verifySignatures: false)!);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.state, TableState.finished);
    expect(v.vouched, isFalse);
    expect(v.totals, t.clients.first.game.totals);
    t.close();
  });

  group('with real keys, bent anywhere', () {
    late Map<String, Object?> json;
    late PublicKey house;
    setUpAll(() {
      final houseKey = SchnorrSigner.generate();
      house = houseKey.publicKey;
      final t = SimTable(
          humans: 2, seed: 103, crypto: crypto, target: 1, keys: [SchnorrSigner.generate(), SchnorrSigner.generate()], houseKey: houseKey);
      t.start();
      expect(t.run(), isTrue);
      json = stored(GameRecord.of(t.clients.first));
      t.close();
    });

    RecordVerdict check(Map<String, Object?> j) {
      final r = GameRecord.parse(j);
      return r == null ? const RecordVerdict(ok: false, reason: 'does not read') : verifyRecord(r, crypto: crypto, house: house);
    }

    Map<String, Object?> copy() => jsonDecode(jsonEncode(json)) as Map<String, Object?>;
    List<Map<String, Object?>> logOf(Map<String, Object?> j) => [for (final e in j['log'] as List) e as Map<String, Object?>];
    int firstOf(Map<String, Object?> j, String kind) => logOf(j).indexWhere((e) => (e['e'] as Map?)?['kind'] == kind);

    test('unbent, every signature checked, it does', () {
      final v = check(json);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.vouched, isTrue);
      expect(v.state, TableState.finished);
    });

    final bends = <String, Map<String, Object?> Function(Map<String, Object?>)>{
      'an entry dropped': (j) => j..['log'] = (logOf(j)..removeAt(5)),
      'two entries swapped, numbered again': (j) {
        final log = logOf(j);
        final a = log[6], b = log[7];
        log[6] = {...b, 'n': 6};
        log[7] = {...a, 'n': 7};
        return j..['log'] = log;
      },
      'an entry\'s time moved': (j) {
        final log = logOf(j);
        log[10] = {...log[10], 't': (log[10]['t'] as int) + 1};
        return j..['log'] = log;
      },
      'a card changed, its id made again': (j) {
        final log = logOf(j);
        final at = firstOf(j, 'play');
        final e = Map<String, Object?>.from(log[at]['e'] as Map);
        final body = Map<String, Object?>.from(e['body'] as Map)..['card'] = 'AS';
        final sorted = Map.fromEntries(body.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
        e['body'] = body;
        e['id'] = sha256Hex(utf8.encode(jsonEncode([e['table'], e['author'], e['kind'], sorted])));
        log[at] = {...log[at], 'e': e};
        return j..['log'] = log;
      },
      'the result said by a person': (j) {
        final log = logOf(j);
        final at = firstOf(j, 'result');
        final said = TableEvent.parse(Map<String, Object?>.from(log[at]['e'] as Map))!;
        final forged = TableEvent.sign(SchnorrSigner.generate(), table: said.table, kind: EventKind.result, body: said.body);
        log[at] = {...log[at], 'e': forged.toJson()};
        return j..['log'] = log;
      },
      'the spec changed': (j) => j..['spec'] = {...(j['spec'] as Map), 'target': 99},
    };
    for (final b in bends.entries) {
      test(b.key, () {
        final v = check(b.value(copy()));
        printOnFailure('${v.state} vouched ${v.vouched} ${v.reason}');
        expect(v.ok, isFalse, reason: '${b.key}, and still it checked');
      });
    }
  });
}
