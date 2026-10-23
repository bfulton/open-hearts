/// Confetti for a moon the player shot (ui/confetti.dart): over the
/// whole table as the sheet comes in, once, for the player's own moon
/// and nobody else's, and never where the device asks for less motion.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/confetti.dart';
import 'package:open_hearts/ui/overlays.dart';

const _names = ['Ada', 'Bao', 'You', 'Dee'];
const _me = 2;

/// [sheet] on a phone-sized table, the device asking for less motion
/// when [still].
Future<void> _pump(WidgetTester tester, Widget sheet, {bool still = false}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: still), child: child!),
    home: Scaffold(body: sheet),
  ));
}

HandOverSheet _hand(int? shooter, {VoidCallback? onNext}) => HandOverSheet(
      handNumber: 0,
      scores: const [26, 26, 0, 26],
      totals: const [26, 26, 0, 26],
      moonShooter: shooter,
      names: _names,
      mySeat: _me,
      onNext: onNext ?? () {},
    );

/// What the shower draws, while it falls.
Finder get _shower => find.descendant(of: find.byType(Confetti), matching: find.byType(CustomPaint));

/// A game to 1 point, dealt from seed 52 and played by each seat's first
/// legal card, whose one hand seat 2 shoots the moon in.
engine.HeartsGame _endedOnAMoon() {
  final game = engine.HeartsGame(seed: 52, target: 1);
  while (game.phase != engine.Phase.gameOver) {
    if (game.phase == engine.Phase.passing) {
      for (var seat = 0; seat < engine.seatCount; seat++) {
        if (!game.hasPassed(seat)) game.setPass(seat, game.handOf(seat).take(3).toList());
      }
    } else if (game.pendingTrick != null) {
      game.collectTrick();
    } else {
      final seat = game.currentSeat!;
      game.play(seat, game.legalPlaysFor(seat).first);
    }
  }
  return game;
}

void main() {
  testWidgets('a moon you shot rains confetti over the whole table, which a tap goes through, and then it is gone', (tester) async {
    var next = 0;
    await _pump(tester, _hand(_me, onNext: () => next++));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('You shot the moon'), findsOneWidget);
    expect(tester.getRect(find.byType(Confetti)), tester.getRect(find.byType(HandOverSheet)), reason: 'over the table, not the sheet alone');
    expect(tester.getSize(find.byType(Confetti)), const Size(390, 844));
    expect(tester.renderObject(_shower), paints..rect());

    // Falling, it is no more than something to look at.
    await tester.tap(find.text('Next hand'));
    expect(next, 1, reason: 'a tap goes through it');

    await tester.pump(confettiFalls);
    expect(tester.renderObject(_shower), paintsNothing, reason: 'once, and then gone');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('nobody else\'s moon, and no moon, has any', (tester) async {
    await _pump(tester, _hand(0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Ada shot the moon'), findsOneWidget);
    expect(find.byType(Confetti), findsNothing);
    await _pump(tester, _hand(null));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Confetti), findsNothing);
  });

  testWidgets('none where the device asks for less motion', (tester) async {
    await _pump(tester, _hand(_me), still: true);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('You shot the moon'), findsOneWidget);
    expect(_shower, findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'nothing falling, so nothing to draw');
  });

  testWidgets('the game\'s last hand a moon you shot: confetti over the game\'s end too, and only yours', (tester) async {
    final game = _endedOnAMoon();
    expect(game.moonShooter, _me);
    await _pump(tester, GameOverSheet(game: game, names: _names, mySeat: _me, onNewGame: () {}));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.renderObject(_shower), paints..rect());
    await _pump(tester, GameOverSheet(game: game, names: _names, mySeat: 0, onNewGame: () {}));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Confetti), findsNothing);
  });
}
