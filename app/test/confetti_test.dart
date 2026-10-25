/// Confetti for a game the player won (ui/confetti.dart): falling as
/// the sheet comes in, some of it behind the sheet and some in front,
/// once, and never where the device asks for less motion.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/table_model.dart' show SeatLook;
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/confetti.dart';
import 'package:open_hearts/ui/overlays.dart';

const _names = ['Ada', 'Bao', 'You', 'Dee'];
final _seats = [for (final n in _names) SeatLook(name: n)];

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

/// A game to 10 played out by each seat's first legal card: the first
/// seed to end it with one winner, and that winner's seat.
({engine.HeartsGame game, int won}) _finished() {
  for (var seed = 1;; seed++) {
    final game = engine.HeartsGame(seed: seed, target: 10);
    while (game.phase != engine.Phase.gameOver) {
      if (game.phase == engine.Phase.passing) {
        for (var seat = 0; seat < engine.seatCount; seat++) {
          if (!game.hasPassed(seat)) game.setPass(seat, game.handOf(seat).take(3).toList());
        }
      } else if (game.phase == engine.Phase.handOver) {
        game.nextHand();
      } else if (game.pendingTrick != null) {
        game.collectTrick();
      } else {
        final seat = game.currentSeat!;
        game.play(seat, game.legalPlaysFor(seat).first);
      }
    }
    if (game.winners.length == 1) return (game: game, won: game.winners.single);
  }
}

/// What a layer of the shower draws, while it falls.
Finder _shower(Key layer) => find.descendant(of: find.byKey(layer), matching: find.byType(CustomPaint));

void main() {
  testWidgets('a game you won rains confetti, behind the sheet and in front of it, which a tap goes through, and then it is gone',
      (tester) async {
    final over = _finished();
    var again = 0;
    await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: over.won, onNewGame: () => again++));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('You win'), findsOneWidget);

    // Behind the sheet's card and in front of it, in one stack with it.
    final stack = tester.widget<Stack>(find.ancestor(of: find.byKey(confettiBehind), matching: find.byType(Stack)).first);
    Key? keyOf(Widget w) => w is Positioned ? w.child.key : null;
    expect(keyOf(stack.children.first), confettiBehind);
    expect(keyOf(stack.children.last), confettiInFront);
    expect(stack.children.length, 3, reason: 'the card between them');
    for (final layer in [confettiBehind, confettiInFront]) {
      expect(tester.getSize(find.byKey(layer)), const Size(390, 844), reason: 'over the whole table');
      expect(tester.renderObject(_shower(layer)), paints..rect());
    }

    await tester.tap(find.text('New game'));
    expect(again, 1, reason: 'a tap goes through it');

    await tester.pump(confettiFalls);
    for (final layer in [confettiBehind, confettiInFront]) {
      expect(tester.renderObject(_shower(layer)), paintsNothing, reason: 'once, and then gone');
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('in red, white and pink, and nothing else', (tester) async {
    final over = _finished();
    await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: over.won, onNewGame: () {}));
    await tester.pump(const Duration(milliseconds: 300));
    final colours = <int>{};
    for (final layer in [confettiBehind, confettiInFront]) {
      final painter = tester.widget<CustomPaint>(_shower(layer)).painter!;
      final recorder = _Colours();
      painter.paint(recorder, const Size(390, 844));
      colours.addAll(recorder.seen);
    }
    expect(colours, {Palette.red.toARGB32(), Palette.cardFace.toARGB32(), Palette.pink.toARGB32()});
  });

  testWidgets('a game somebody else won has none, nor does a hand, a moon shot included', (tester) async {
    final over = _finished();
    await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: (over.won + 1) % engine.seatCount, onNewGame: () {}));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Confetti), findsNothing);
    await _pump(
      tester,
      HandOverSheet(
        handNumber: 0,
        scores: const [26, 26, 0, 26],
        totals: const [26, 26, 0, 26],
        moonShooter: 2,
        seats: _seats,
        mySeat: 2,
        onNext: () {},
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('You shot the moon'), findsOneWidget);
    expect(find.byType(Confetti), findsNothing);
  });

  testWidgets('none where the device asks for less motion', (tester) async {
    final over = _finished();
    await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: over.won, onNewGame: () {}), still: true);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('You win'), findsOneWidget);
    expect(find.descendant(of: find.byType(Confetti), matching: find.byType(CustomPaint)), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'nothing falling, so nothing to draw');
  });
}

/// A canvas that keeps the colours drawn on it, at full strength.
class _Colours implements Canvas {
  final seen = <int>{};

  void _note(Paint paint) => seen.add(paint.color.withValues(alpha: 1).toARGB32());

  @override
  void drawRect(Rect rect, Paint paint) => _note(paint);

  @override
  void drawCircle(Offset c, double radius, Paint paint) => _note(paint);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
