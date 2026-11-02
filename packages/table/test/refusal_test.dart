/// A table the house will not serve (house.dart, packages/table;
/// docs/explanation/live-play.md, "When the house will not serve a
/// table"): it says so once, in the table's own log, and the table ends
/// there, failed. The referee asks for the house until it has said its
/// word on the table (service/do/referee.mjs), so a house that only let
/// such a table go was woken for it every twenty seconds until the
/// log's notes ran out, some eleven days.
library;

import 'dart:convert';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// BIP-340's own published pair: the service of these tests (accounts_test.dart).
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

Licence _licenceFor(PublicKey key, String account, {DateTime? until}) {
  final day = until ?? DateTime.utc(2099, 1, 1);
  final unsigned = Licence(key: key, account: account, until: day, plan: 'year', signature: '');
  return Licence(key: key, account: account, until: day, plan: 'year', signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest));
}

/// The house's words in the table's log of [t], in order: its results.
/// (What else it says at a table it serves, it says as the bot seats.)
List<TableEvent> _houseSaid(SimTable t) => [
      for (final e in t.referee.log)
        if (e.event != null && e.event!.kind == EventKind.result && e.event!.author == t.houseSigner.publicKey) e.event!,
    ];

/// Everything the house signed in the table's log of [t].
List<TableEvent> _houseEvents(SimTable t) => [
      for (final e in t.referee.log)
        if (e.event != null && e.event!.author == t.houseSigner.publicKey) e.event!,
    ];

/// How many times the table's object wakes the house after it started
/// [t], in [forMs] of the clock: as the object does
/// (service/do/referee.mjs, tableReferee.wantsHouse, wakeLimiter) — every
/// twenty seconds, while the table has begun, the house is not on it, and
/// its word on the table is not in the log. The wake as the table starts
/// is the simulator's own (SimTable, referee.onStart) and not counted.
int _wakes(SimTable t, {required int forMs}) {
  var wakes = 0;
  bool said() => t.referee.log.any((e) => e.event?.kind == EventKind.result && e.event!.author == t.houseSigner.publicKey);
  void wake() {
    if (t.referee.log.isNotEmpty && !said() && !t.house!.serving.contains(t.spec.id)) {
      wakes++;
      t.house!.serve(t.spec.id);
    }
    t.clock.schedule(20 * 1000, wake);
  }

  t.clock.schedule(20 * 1000, wake);
  t.start();
  t.clock.advance(forMs);
  return wakes;
}

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());
  tearDown(() => licenceService = '');

  group('the rules', () {
    final house = FakeSigner('refusal house');
    final p0 = FakeSigner('refusal p0');
    final p1 = FakeSigner('refusal p1');
    late TableSpec spec;
    late TableRules rules;
    var n = 0;
    var t = 0;

    TableEvent say(Signer by, Map<String, Object?> body) => TableEvent.sign(by, table: spec.id, kind: EventKind.result, body: body);
    void feed(TableEvent e) => rules.feed(LogEntry(n: n++, t: t += 10, event: e));

    setUp(() {
      spec = TableSpec(
        seed: 9,
        sealed: true,
        house: house.publicKey,
        seats: [HumanSeat(p0.publicKey), HumanSeat(p1.publicKey), const BotSeat(Persona.romeo), const BotSeat(Persona.juliet)],
      );
      rules = TableRules(tableId: spec.id, crypto: crypto);
      n = 0;
      t = 1000000;
    });

    test('names the log as it stood after its start, and says failed; there is none before the start', () {
      expect(rules.refusal, isNull);
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.start, body: {'spec': spec.toJson()}));
      final afterStart = LogHash()..add(rules.log.first);
      expect(rules.refusal, {'n': 1, 'hash': afterStart.value, 'state': 'failed', 'totals': [0, 0, 0, 0]});
      expect(rules.state, TableState.playing);
    });

    test('ends the table at once, failed, for every side that reads the log', () {
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.start, body: {'spec': spec.toJson()}));
      expect(rules.owed, isNotEmpty);
      // More came before the house's word, as it does: the word names the
      // start all the same.
      feed(TableEvent.sign(p1, table: spec.id, kind: EventKind.leave, body: {'seat': 1}));
      final word = say(house, rules.refusal!);
      feed(word);
      expect(rules.state, TableState.failed);
      expect(rules.over, isTrue);
      expect(rules.result?.id, word.id, reason: 'the house\'s word is in');
      expect(rules.owed, isEmpty);
      // Nothing is taken after it.
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.leave, body: {'seat': 0}));
      expect(rules.state, TableState.failed);
      expect(rules.removals.keys, [1], reason: 'only what came before it');
    });

    test('is taken from the house alone, and only as it is: failed, naming the start', () {
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.start, body: {'spec': spec.toJson()}));
      final word = rules.refusal!;
      for (final (why, forged) in [
        ('a person', say(p0, word)),
        ('another house', say(FakeSigner('another house'), word)),
        ('another log', say(house, {...word, 'n': 2})),
        ('another hash', say(house, {...word, 'hash': rules.log.first.event!.id})),
        ('finished', say(house, {...word, 'state': 'finished'})),
        ('ended', say(house, {...word, 'state': 'ended'})),
      ]) {
        feed(forged);
        expect(rules.state, TableState.playing, reason: why);
        expect(rules.result, isNull, reason: why);
      }
      feed(say(house, word));
      expect(rules.state, TableState.failed);
    });

    test('is not read at a table already over by its own rules: it keeps the end it had', () {
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.start, body: {'spec': spec.toJson()}));
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.leave, body: {'seat': 0}));
      feed(TableEvent.sign(p1, table: spec.id, kind: EventKind.leave, body: {'seat': 1}));
      expect(rules.state, TableState.ended);
      feed(say(house, rules.refusal!));
      expect(rules.state, TableState.ended);
      expect(rules.result, isNull);
    });

    test('rates nobody: a failed game has no result to publish', () {
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.start, body: {'spec': spec.toJson()}));
      feed(say(house, rules.refusal!));
      expect(GameResult.ofTable(rules), isNull);
    });

    test('is the same table to one with no seat, replaying the kept log', () {
      feed(TableEvent.sign(p0, table: spec.id, kind: EventKind.start, body: {'spec': spec.toJson()}));
      feed(say(house, rules.refusal!));
      final verdict = verifyRecord(GameRecord(spec: spec, log: rules.log), crypto: crypto, house: house.publicKey);
      expect(verdict.ok, isTrue, reason: verdict.reason);
      expect(verdict.state, TableState.failed);
      expect(verdict.vouched, isTrue);
    });
  });

  group('the house', () {
    /// Two people, each with a licence for their own key unless [without]
    /// names theirs.
    SimTable licensed({int? without, bool rated = false, String? salt}) {
      licenceService = _service;
      const seed = 41;
      final second = FakeSigner('p1-$seed').publicKey;
      return SimTable(
        humans: 2,
        seed: seed,
        target: 1,
        crypto: crypto,
        rated: rated,
        salt: salt,
        licenceOf: (key) => without == 1 && key == second ? null : _licenceFor(key, key.substring(0, 32)),
      );
    }

    // Every reason the house refuses a table that is final: what it
    // checks is the start, which never changes, against the service's
    // key and its own secret, which are fixed as it starts.
    final refused = <String, SimTable Function()>{
      'a seat that shows no licence': () => licensed(without: 1),
      'a rated table with a salt of a device\'s own': () => SimTable(humans: 2, seed: 112, target: 1, crypto: crypto, rated: true, salt: newSalt(Random(1))),
    };

    for (final MapEntry(key: why, value: make) in refused.entries) {
      group('refusing $why', () {
        test('says so once in the table\'s log, which ends the table at every side at once, and publishes nothing', () {
          final t = make()..start();
          expect(t.run(), isTrue, reason: 'ends, the house\'s word in the log, and the house let go');
          expect(t.following.map((c) => c.state), everyElement(TableState.failed));
          final said = _houseEvents(t);
          expect(said, hasLength(1), reason: 'it plays no seat and deals nothing');
          expect(said.single.kind, EventKind.result);
          expect(said.single.body, t.clients.first.rules.refusal);
          expect(t.clients.first.rules.result?.id, said.single.id, reason: 'every side took it for the end');
          expect(t.house!.serving, isEmpty, reason: 'the house let the table go');
          // Not a turn of the house's running out: no time was asked for.
          expect(t.referee.log.where((e) => e.isTick), isEmpty);
          // The ratings are folded from what the house publishes: nothing.
          expect(t.results, isEmpty);
          expect(GameResult.ofTable(t.clients.first.rules), isNull);
          t.close();
        });

        test('reads no more of the table than its start', () {
          final t = make()..start();
          t.run();
          expect(t.views['house follower']!.keys, [0]);
          t.close();
        });

        test('is not woken again, however long the table stands', () {
          final t = make();
          final wakes = _wakes(t, forMs: 60 * 60 * 1000);
          expect(wakes, 0, reason: 'woken $wakes more times in an hour');
          expect(t.referee.log.where((e) => e.up == t.houseSigner.publicKey || e.down == t.houseSigner.publicKey), hasLength(1),
              reason: 'it came and it went, and not again');
          t.close();
        });
      });
    }

    // A start the referee takes, since it checks only that the id is the
    // spec's, and that this build does not read: it plays no revision of
    // the deal but its own (rules.dart, _start). Nobody here plays such a
    // table, the house included, which could say nothing of what it could
    // not read, and so was woken for it until the log's notes ran out,
    // some eleven days: the referee asks for the house until it has said a
    // result, whatever the result says. No side reads the word either, the
    // table having failed at its start for every side that reads as this
    // one does.
    group('refusing a start of another revision of the deal', () {
      SimTable make() => SimTable(humans: 2, seed: 114, target: 1, crypto: crypto, deal: 1);

      test('says so once in the table\'s log, naming the start, and lets the table go; the table is failed everywhere', () {
        final t = make()..start();
        expect(t.clock.runUntil(() => _houseSaid(t).isNotEmpty && t.house!.serving.isEmpty, limitMs: 60 * 60 * 1000), isTrue,
            reason: 'the house\'s word is in the log and the house let the table go');
        expect(t.following.map((c) => c.state), everyElement(TableState.failed));
        expect(t.following.map((c) => c.started), everyElement(isFalse), reason: 'nobody read the start');
        final said = _houseEvents(t);
        expect(said, hasLength(1), reason: 'it plays no seat and deals nothing');
        expect(said.single.kind, EventKind.result);
        final afterStart = LogHash()..add(t.referee.log.first);
        expect(said.single.body, {'n': 1, 'hash': afterStart.value, 'state': 'failed', 'totals': [0, 0, 0, 0]});
        expect(t.results, isEmpty, reason: 'nothing reaches the results tag');
        t.close();
      });

      test('is not woken again, however long the table stands', () {
        final t = make();
        final wakes = _wakes(t, forMs: 60 * 60 * 1000);
        expect(wakes, 0, reason: 'woken $wakes more times in an hour');
        expect(t.house!.serving, isEmpty, reason: 'the house followed it no longer');
        expect(t.referee.log.where((e) => e.up == t.houseSigner.publicKey || e.down == t.houseSigner.publicKey), hasLength(1),
            reason: 'it came and it went, and not again');
        t.close();
      });
    });

    test('its word is the table\'s and no result: said on the results tag, it would be folded for nobody', () {
      final t = refused['a seat that shows no licence']!()..start();
      t.run();
      final word = _houseSaid(t).single;
      final onTheTag = NostrEvent.sign(t.houseSigner, kind: TableKinds.lobby, content: jsonEncode(word.body), tags: [
        ['t', GameResult.tag]
      ]);
      expect(GameResult.parse(onTheTag), isNull);
      expect(Ledger.from([onTheTag], house: t.houseSigner.publicKey).standing, isEmpty);
      t.close();
    });

    // What it serves gets no such word: a refusal is for a table it will
    // not serve, and only for one.
    final served = <String, SimTable Function()>{
      'a friends\' table': () => SimTable(humans: 2, seed: 111, target: 1, crypto: crypto),
      'a pool\'s rated table': () => SimTable(humans: 2, seed: 112, target: 1, crypto: crypto, rated: true),
      'a table whose seats all show their licences': () => licensed(),
      'a table with one person at it who never said a word': () => SimTable(humans: 2, seed: 113, target: 1, crypto: crypto),
    };

    for (final MapEntry(key: what, value: make) in served.entries) {
      test('serving $what, it says its word on how the game came out and no refusal', () {
        final t = make();
        if (what.contains('never said')) {
          t.people.first.start();
          expect(t.clock.runUntil(() => t.clients.first.done && t.clients.first.rules.result != null && t.house!.serving.isEmpty, limitMs: 60 * 60 * 1000), isTrue);
        } else {
          t.start();
          expect(t.run(), isTrue);
        }
        final rules = t.clients.first.rules;
        expect(rules.state, TableState.finished);
        final said = _houseSaid(t);
        expect(said, hasLength(1));
        expect(said.single.body['state'], 'finished');
        expect(said.single.body['n'], rules.endN, reason: 'the game\'s end, not the start');
        expect(said.single.body, isNot(rules.refusal));
        // The silent person's table is none the house publishes a result for (resultOf).
        expect(t.results, hasLength(what.contains('never said') ? 0 : 1));
        t.close();
      });
    }

    test('a licence that has run out since the table began does not make it refused: the check is of the start, never of the day', () {
      // Good on the simulator's day, the first of 1970 when the table
      // starts, and long run out by the real one: a house that started
      // again mid-game would see the day, and the same table twice.
      licenceService = _service;
      final t = SimTable(
        humans: 2,
        seed: 41,
        target: 1,
        crypto: crypto,
        licenceOf: (key) => _licenceFor(key, key.substring(0, 32), until: DateTime.utc(1970, 1, 1)),
      )..start();
      expect(t.run(), isTrue);
      expect(t.following.map((c) => c.state), everyElement(TableState.finished));
      expect(_houseSaid(t).map((e) => e.body['state']), ['finished']);
      t.close();
    });

    test('a house that has not reached the table says nothing of it, and the table ends by its own rules', () {
      final t = licensed(rated: false);
      // Nobody woke it.
      t.referee.onStart = null;
      t.start();
      t.clock.advance(10 * 60 * 1000);
      expect(_houseEvents(t), isEmpty);
      expect(t.following.map((c) => c.state), everyElement(TableState.failed), reason: 'its turn ran out');
      t.close();
    });

    test('a house that comes late serves the table it finds, and refuses nothing', () {
      final t = licensed(rated: false);
      t.referee.onStart = (s) => t.clock.schedule(20 * 1000, () => t.house!.serve(s.id));
      t.start();
      expect(t.run(), isTrue);
      expect(t.following.map((c) => c.state), everyElement(TableState.finished));
      expect(_houseSaid(t).map((e) => e.body['state']), ['finished']);
      t.close();
    });

    test('a house that goes and comes back mid-game finds the table as it was, and refuses nothing', () {
      final t = licensed(rated: false)..start();
      t.clock.schedule(700, () => t.restartHouse(afterMs: 5000));
      expect(t.run(), isTrue);
      expect(t.following.map((c) => c.state), everyElement(TableState.finished));
      expect(_houseSaid(t).map((e) => e.body['state']), ['finished']);
      t.close();
    });
  });
}
