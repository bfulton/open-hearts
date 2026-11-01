/// A refereed game's result (results.dart, version 3): the house's word,
/// made from the log once the game is over, and the only one the ledger
/// takes for a table since the referee.
library;

import 'dart:math';

import 'package:deal/deal.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late SimTable t;
  late TableRules over;
  setUpAll(() async {
    final crypto = await rememberedCrypto();
    t = SimTable(humans: 2, seed: 111, crypto: crypto, rated: true);
    t.people[1]
      ..going = Going.leave
      ..goAt = Moment.midTrick;
    t.start();
    expect(t.run(), isTrue);
    over = t.clients.first.rules;
    t.close();
  });

  test('is made from the log once the game is over: its end, its totals, who left', () {
    final r = GameResult.ofTable(over)!;
    expect(r.v, 3);
    expect(r.state, TableState.finished.name);
    expect(r.endN, over.endN);
    expect(r.endHash, over.endHash);
    expect(r.rated, isTrue);
    final people = r.seats.where((s) => s.human).toList();
    expect(people, hasLength(2));
    expect(people.singleWhere((s) => s.left).key, t.signers[1].publicKey, reason: 'the leaver finishes last');
    expect(r.seats.where((s) => !s.human && !s.fromStart), hasLength(1), reason: 'and the bot that finished the seat has no stake');
    expect([for (final s in r.seats.where((s) => !s.left)) s.total]..sort(), isNotEmpty);
  });

  test('reads back as the house said it', () {
    final said = GameResult.ofTable(over)!.signedBy(t.houseSigner);
    expect(said.tag('t'), GameResult.tag);
    final back = GameResult.parse(said)!;
    expect(back.toJson(), GameResult.ofTable(over)!.toJson());
  });

  test('the house publishes it, signed, once its word is in the log', () {
    expect(t.results, hasLength(1));
    final said = t.results.single;
    expect(said.pubkey, t.houseSigner.publicKey);
    expect(GameResult.parse(said)!.toJson(), GameResult.ofTable(over)!.toJson());
  });

  test('a game that failed has no result', () {
    final failed = TableRules(tableId: 'x');
    expect(GameResult.ofTable(failed), isNull);
  });

  group('the ledger', () {
    Signer house() => t.houseSigner;
    PublicKey person(int i) => t.signers[i].publicKey;

    test('takes the house\'s word on a table, and rates who sat at it', () {
      final l = Ledger.from([GameResult.ofTable(over)!.signedBy(house())], house: house().publicKey);
      expect(l.standing, hasLength(1));
      expect(l.gamesOf(person(0)), 1);
      expect(l.gamesOf(person(1)), 1, reason: 'the leaver too, as last');
    });

    test('takes no one else\'s: not a person\'s, not every person\'s, not another house\'s', () {
      final r = GameResult.ofTable(over)!;
      expect(Ledger.from([r.signedBy(t.signers[0])], house: house().publicKey).standing, isEmpty);
      expect(Ledger.from([r.signedBy(t.signers[0]), r.signedBy(t.signers[1])], house: house().publicKey).standing, isEmpty,
          reason: 'a majority of the table is nothing to a refereed table\'s result');
      expect(Ledger.from([r.signedBy(FakeSigner('another house'))], house: house().publicKey).standing, isEmpty);
      expect(Ledger.from([r.signedBy(house())]).standing, isEmpty, reason: 'nobody\'s word without knowing whose the house is');
    });

    test('takes the house\'s first word on a table, once', () {
      final r = GameResult.ofTable(over)!;
      final other = GameResult(table: r.table, rated: true, seats: r.seats.reversed.toList(), at: 0, v: 3, state: r.state, endN: r.endN, endHash: r.endHash);
      final l = Ledger.from([r.signedBy(house()), other.signedBy(house())], house: house().publicKey);
      expect(l.standing, hasLength(1));
      expect(l.standing.single.seats.first.id, r.seats.first.id);
    });
  });

  group('the house says one', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    // [t] with only its first person there: the rest never come.
    TableRules alone(SimTable t) {
      t.people.first.start();
      final c = t.clients.first;
      expect(t.clock.runUntil(() => c.done && c.rules.result != null && t.house!.serving.isEmpty, limitMs: 60 * 60 * 1000), isTrue);
      return c.rules;
    }

    test('for a rated table only when it seated it: one a device started as rated is not served, and nobody is rated on it', () {
      // Any one of a table's people can write its start: rated, naming
      // whoever they like, with a salt of their own.
      final t = SimTable(humans: 2, seed: 112, target: 1, crypto: crypto, rated: true, salt: newSalt(Random(1)))..start();
      t.run(limitMs: 10 * 60 * 1000);
      expect(t.following.map((c) => c.state), everyElement(TableState.failed));
      expect(t.house!.serving, isEmpty, reason: 'the house let the table go');
      expect(t.results, isEmpty);
      expect(t.referee.log.where((e) => e.event?.author == t.houseSigner.publicKey), isEmpty, reason: 'the house said nothing at it');
      t.close();
    });

    test('for a pool\'s table, about everyone it seated, whether they came or not', () {
      final t = SimTable(humans: 2, seed: 113, target: 1, crypto: crypto, rated: true);
      final over = alone(t);
      expect(over.removals[1]?.exit, Exit.booted);
      final said = GameResult.parse(t.results.single)!;
      expect(said.rated, isTrue);
      expect(said.seats.singleWhere((s) => s.key == t.signers[1].publicKey).left, isTrue, reason: 'seated, and gone');
      t.close();
    });

    test('for a table a device started, none when one of its people never said a word there', () {
      // Whoever starts a table chooses who sits at it: somebody named
      // there who never said anything never sat down to it.
      final t = SimTable(humans: 2, seed: 113, target: 1, crypto: crypto);
      final over = alone(t);
      expect(over.state, TableState.finished, reason: 'the game went on with a bot in the empty seat');
      expect(over.removals[1]?.exit, Exit.booted);
      expect(t.results, isEmpty);
      t.close();
    });
  });
}
