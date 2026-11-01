/// What the profile counts, and where each half of it comes from.
///
/// The games played alone are on the device as records — a seed and
/// every card the player chose — so counting them means playing them
/// again. That is the test: a game played by thumb, and the tally the
/// profile would show for it, against the scores the game itself
/// ended on.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/net/standing.dart' as net;
import 'package:open_hearts/record_store.dart';
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

import 'table_page_test.dart' show fanCards, tapCard;

void main() {
  testWidgets('a game played alone is counted from its own record', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const TablePage(seed: 11, paced: false)));
    await tester.pumpAndSettle();
    for (var guard = 0; guard < 2000; guard++) {
      await tester.pumpAndSettle();
      if (find.text('New game').evaluate().isNotEmpty) break;
      if (find.text('Next hand').evaluate().isNotEmpty) {
        await tester.tap(find.text('Next hand'));
        continue;
      }
      if (find.widgetWithText(FilledButton, 'Pass').evaluate().isNotEmpty) {
        final hand = fanCards(tester);
        for (var i = 0; i < 3; i++) {
          await tapCard(tester, hand[i].card);
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
        continue;
      }
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
    }
    final controller = tester.widget<TableView>(find.byType(TableView)).controller as GameController;
    final game = controller.game;
    expect(game.phase, engine.Phase.gameOver);

    final kept = await PrefsRecordStore().load();
    final tally = soloGames(kept).tally;
    expect(tally.games, 1);
    expect(tally.points, game.totals[controller.mySeat], reason: 'the score the game actually ended on');
    expect(tally.best, game.totals[controller.mySeat]);
    expect(tally.won, game.winners.contains(controller.mySeat) ? 1 : 0);
    expect(tally.average, tally.points.toDouble());

    // The same game twice over is two games and the same average.
    final twice = soloGames([...kept, ...kept]).tally;
    expect(twice.games, 2);
    expect(twice.average, tally.average);

    // Hand by hand: the game's own score on the chart, and every hand
    // played counted once.
    final history = soloGames(kept).history;
    expect(history.recent, [game.totals[controller.mySeat]]);
    expect(history.hands, game.handNumber + 1);
    expect(history.average, game.totals[controller.mySeat].toDouble());
    expect(soloGames([...kept, ...kept]).history.hands, 2 * history.hands);
  });

  testWidgets('the chart is the last twenty finished games, oldest first', (tester) async {
    // Twenty-two games played to the end through the controller, each
    // kept as the app keeps them — newest first — and one left half way.
    final store = MemoryRecordStore();
    final finals = <int>[];
    for (var seed = 1; seed <= 22; seed++) {
      final c = GameController(seed: seed, paced: false, store: store);
      while (c.game.phase != engine.Phase.gameOver) {
        if (c.awaitingPass) {
          for (final card in c.game.handOf(c.mySeat).take(engine.passSize)) {
            c.toggleSelected(card);
          }
          c.confirmPass();
        } else if (c.awaitingPlay) {
          c.playCard(c.legalNow.first);
        } else if (c.game.phase == engine.Phase.handOver) {
          c.nextHand();
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(seconds: 1));
      finals.add(c.game.totals[c.mySeat]);
      c.dispose();
    }
    final kept = await store.load();
    expect(kept, hasLength(22));
    final history = soloGames(['oh1:5:Cyrano,Juliet,Tristan:-:2C', ...kept]).history;
    expect(history.recent, finals.sublist(2), reason: 'the newest twenty, the oldest of them first');
  });

  group('what one hand says', () {
    final c = engine.Card.parse;
    // A trick its winner leads with the highest of the suit; the rest
    // follow lower or throw off.
    List<engine.Play> trick(int winner, String lead, List<String> rest) => [
          engine.Play(winner, c(lead)),
          for (var i = 0; i < 3; i++) engine.Play((winner + 1 + i) % 4, c(rest[i])),
        ];

    test('the queen is whoever took the trick she fell in', () {
      final hand = [trick(2, 'KS', ['QS', '2C', '3C'])];
      expect(handFacts(hand, moonShooter: null, me: 2).queen, isTrue);
      expect(handFacts(hand, moonShooter: null, me: 3).queen, isFalse, reason: 'she was thrown, not won');
    });

    test('a run broken up: the queen and ten hearts to one, a heart of theirs to me', () {
      final run = [
        trick(1, 'AS', ['QS', '2C', '3C']),
        trick(1, 'AH', ['KH', 'QH', 'JH']),
        trick(1, '10H', ['9H', '8H', '7H']),
        trick(1, '6H', ['5H', '4H', '2D']),
        // The one that got away: the 3 of hearts to seat 0.
        trick(0, 'AC', ['3H', '4C', '5C']),
      ];
      final facts = handFacts(run, moonShooter: null, me: 0);
      expect(facts.blocked, isTrue);
      expect(facts.queen, isFalse);
      expect(handFacts(run, moonShooter: null, me: 2).blocked, isFalse, reason: 'seat 2 took no heart');
      expect(handFacts(run, moonShooter: null, me: 1).blocked, isFalse, reason: 'nobody blocks their own run');
    });

    test('nine hearts is not a run; a moon shot is a moon, not one blocked', () {
      final nine = [
        trick(1, 'AS', ['QS', '2C', '3C']),
        trick(1, 'AH', ['KH', 'QH', 'JH']),
        trick(1, '10H', ['9H', '8H', '7H']),
        trick(1, '6H', ['2D', '3D', '4D']),
        trick(0, 'AC', ['5H', '4C', '5C']),
      ];
      expect(handFacts(nine, moonShooter: null, me: 0).blocked, isFalse);
      expect(handFacts(nine, moonShooter: 1, me: 0).blocked, isFalse);
      expect(handFacts(nine, moonShooter: 0, me: 0).shot, isTrue);
    });
  });

  test('a record that stops short is not a game anyone finished', () {
    expect(soloGames(const ['not a record at all']).tally.games, 0);
    // A real record with its plays cut off: the game was left, so
    // there is no score to claim for it.
    const whole = 'oh1:11:Cyrano,Juliet,Tristan:-:2C';
    expect(soloGames(const [whole]).tally.games, 0);
  });

  test('a standing folds into the live half', () {
    final me = FakeSigner('me').publicKey;
    final you = FakeSigner('you').publicKey;
    GameResult game(String table, List<int> totals) => GameResult(
          table: table,
          rated: true,
          at: 0,
          seats: [
            SeatResult(human: true, key: me, account: me, total: totals[0], fromStart: true),
            SeatResult(human: true, key: you, account: you, total: totals[1], fromStart: true),
            SeatResult(human: false, bot: 'Romeo', total: totals[2], fromStart: true),
            SeatResult(human: false, bot: 'Juliet', total: totals[3], fromStart: true),
          ],
        );
    final ledger = Ledger();
    ledger.apply(game('t1', [20, 50, 60, 70]));
    ledger.apply(game('t2', [80, 30, 40, 50]));

    final stats = fromStanding(const PlayerStats(), net.Standing(ledger, me));
    expect(stats.asking, isFalse, reason: 'an answer is not a question still out');
    expect(stats.reached, isTrue);
    expect(stats.ratedGames, 2);
    expect(stats.live.games, 2);
    expect(stats.live.won, 1);
    expect(stats.live.average, 50);
    expect(stats.rating!.shown, greaterThan(0));
  });

  test('the relays are said to be asked while they are, and to have failed only once they have', () async {
    SharedPreferences.setMockInitialValues({});
    final me = FakeSigner('me');
    // Nothing listens here: the relay never answers, which is what a
    // device with no network sees too.
    final said = await playerStats(store: PrefsRecordStore(), signer: me, relays: [Uri.parse('ws://127.0.0.1:9')]).toList();
    expect(said.first.asking, isTrue, reason: 'the device\'s own games at once, the relays still to answer');
    expect(said.last.asking, isFalse, reason: 'and the wait ends, in a word rather than a count still under way');
    expect(said.last.reached, isFalse);

    // A door that asks nobody has nothing coming.
    final asked = await playerStats(store: PrefsRecordStore(), signer: me).toList();
    expect(asked.single.asking, isFalse);
  });
}
