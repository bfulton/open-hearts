/// What the profile counts, and where each half of it comes from.
///
/// The games played alone are on the device as records — a seed and
/// every card the player chose — so counting them means playing them
/// again. That is the test: a game played by thumb, and the tally the
/// profile would show for it, against the scores the game itself
/// ended on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' as engine;
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/record_store.dart';
import 'package:open_hearts/net/standing.dart' as net;
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

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
    final tally = soloTally(kept);
    expect(tally.games, 1);
    expect(tally.points, game.totals[controller.mySeat], reason: 'the score the game actually ended on');
    expect(tally.best, game.totals[controller.mySeat]);
    expect(tally.won, game.winners.contains(controller.mySeat) ? 1 : 0);
    expect(tally.average, tally.points.toDouble());

    // The same game twice over is two games and the same average.
    final twice = soloTally([...kept, ...kept]);
    expect(twice.games, 2);
    expect(twice.average, tally.average);
  });

  test('a record that stops short is not a game anyone finished', () {
    expect(soloTally(const ['not a record at all']).games, 0);
    // A real record with its plays cut off: the game was left, so
    // there is no score to claim for it.
    const whole = 'oh1:11:Cyrano,Juliet,Sid:-:2C';
    expect(soloTally(const [whole]).games, 0);
  });

  test('a standing folds into the live half', () {
    final me = FakeSigner('me').publicKey;
    final you = FakeSigner('you').publicKey;
    GameResult game(String table, List<int> totals) => GameResult(
          table: table,
          rated: true,
          at: 0,
          seats: [
            SeatResult(human: true, key: me, total: totals[0], fromStart: true),
            SeatResult(human: true, key: you, total: totals[1], fromStart: true),
            SeatResult(human: false, bot: 'Romeo', total: totals[2], fromStart: true),
            SeatResult(human: false, bot: 'Juliet', total: totals[3], fromStart: true),
          ],
        );
    final ledger = Ledger();
    ledger.apply(game('t1', [20, 50, 60, 70]));
    ledger.apply(game('t2', [80, 30, 40, 50]));

    final stats = fromStanding(const PlayerStats(), net.Standing(ledger, me), me);
    expect(stats.reached, isTrue);
    expect(stats.ratedGames, 2);
    expect(stats.live.games, 2);
    expect(stats.live.won, 1);
    expect(stats.live.average, 50);
    expect(stats.rating!.shown, greaterThan(0));
  });
}
