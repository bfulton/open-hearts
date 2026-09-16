/// Colour carries one meaning each (theme.dart), and this is where that
/// is checked rather than believed.
///
/// **Gold is what you can do.** A button, the card you may play, the
/// seat it is the turn of. Nothing that is not an action wears it: a
/// name, a heading, a score, a rating, a trick that has already been
/// taken. Gold on those teaches the eye that gold means nothing in
/// particular, and then it means nothing when it is the turn to play.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/overlays.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'table_page_test.dart' show fanCards, pumpTable, tapCard;

const _names = ['Ada', 'Bao', 'You', 'Dee'];
const _me = 2;

Future<void> pumpSheet(WidgetTester tester, Widget sheet) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: sheet)));
  await tester.pumpAndSettle();
}

Color _colourOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style!.color!;

/// The background of the button labelled [text].
Color _buttonUnder(WidgetTester tester, String text) {
  final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, text));
  return button.style!.backgroundColor!.resolve({})!;
}

/// A game played out to the end by the first seed that leaves one
/// winner and one loser, and which seats those are. Read from the
/// winner's chair the sheet says one thing and from the loser's
/// another, which is the pair this file is about.
({engine.HeartsGame game, int won, int lost}) _finished() {
  for (var seed = 1; seed < 40; seed++) {
    final game = engine.HeartsGame(seed: seed, target: 10);
    for (var guard = 0; guard < 4000 && game.phase != engine.Phase.gameOver; guard++) {
      if (game.phase == engine.Phase.passing) {
        for (var seat = 0; seat < engine.seatCount; seat++) {
          if (!game.hasPassed(seat)) game.setPass(seat, game.handOf(seat).take(3).toList());
        }
        continue;
      }
      if (game.pendingTrick != null) {
        game.collectTrick();
        continue;
      }
      if (game.phase == engine.Phase.handOver) {
        game.nextHand();
        continue;
      }
      game.play(game.currentSeat!, game.legalPlaysFor(game.currentSeat!).first);
    }
    if (game.phase != engine.Phase.gameOver) continue;
    final totals = game.totals;
    final low = totals.reduce((a, b) => a < b ? a : b);
    final high = totals.reduce((a, b) => a > b ? a : b);
    if (low == high) continue;
    if (totals.where((t) => t == low).length != 1) continue;
    return (game: game, won: totals.indexOf(low), lost: totals.indexOf(high));
  }
  throw StateError('no seed under forty finished with one winner');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the hand that ended is white; the thing to press is gold', (tester) async {
    await pumpSheet(
      tester,
      HandOverSheet(
        handNumber: 0,
        scores: const [3, 8, 2, 13],
        totals: const [3, 8, 2, 13],
        moonShooter: null,
        names: _names,
        mySeat: _me,
        onNext: () {},
      ),
    );
    expect(_colourOf(tester, 'Hand 1'), Palette.chrome, reason: 'which hand it was is a fact');
    expect(_buttonUnder(tester, 'Next hand'), Palette.gold, reason: 'and the one thing to do is gold');
  });

  testWidgets('your own row on the sheet is the weight, not the colour', (tester) async {
    await pumpSheet(
      tester,
      HandOverSheet(
        handNumber: 0,
        scores: const [3, 8, 2, 13],
        totals: const [3, 8, 2, 13],
        moonShooter: null,
        names: _names,
        mySeat: _me,
        onNext: () {},
      ),
    );
    final you = tester.widget<Text>(find.text('You')).style!;
    final them = tester.widget<Text>(find.text('Ada')).style!;
    expect(you.color, Palette.chrome);
    expect(them.color, Palette.chrome);
    expect(you.fontWeight, FontWeight.w700);
    expect(them.fontWeight, isNot(FontWeight.w700), reason: 'which row is yours is said by the weight');
  });

  testWidgets('the moon is white when you shot it and red when somebody else did', (tester) async {
    Widget sheet(int shooter) => HandOverSheet(
          handNumber: 0,
          scores: const [26, 0, 0, 0],
          totals: const [26, 0, 0, 0],
          moonShooter: shooter,
          names: _names,
          mySeat: _me,
          onNext: () {},
        );
    await pumpSheet(tester, sheet(_me));
    expect(_colourOf(tester, 'You shot the moon'), Palette.chrome);
    await pumpSheet(tester, sheet(0));
    expect(_colourOf(tester, 'Ada shot the moon'), Palette.danger);
  });

  testWidgets('a game you won says so in white, and one you lost in red — the new game is gold either way', (tester) async {
    final over = _finished();
    await pumpSheet(tester, GameOverSheet(game: over.game, names: _names, mySeat: over.won, onNewGame: () {}));
    expect(_colourOf(tester, 'You win'), Palette.chrome);
    expect(_buttonUnder(tester, 'New game'), Palette.gold);

    await pumpSheet(tester, GameOverSheet(game: over.game, names: _names, mySeat: over.lost, onNewGame: () {}));
    expect(_colourOf(tester, '${_names[over.won]} wins'), Palette.danger);
    expect(_buttonUnder(tester, 'New game'), Palette.gold, reason: 'the way on is the same colour whoever won');
  });

  testWidgets('what a game did to your rating is a number, up or down', (tester) async {
    final over = _finished();
    final before = Rating.fresh;
    Future<void> show(Rating after) => pumpSheet(
          tester,
          GameOverSheet(
            game: over.game,
            names: _names,
            mySeat: over.won,
            onNewGame: () {},
            rating: (before: before, after: after),
          ),
        );
    final up = Rating(mu: before.mu + 30, phi: 60);
    await show(up);
    expect(_colourOf(tester, '+${up.shown - before.shown}'), Palette.chrome, reason: 'a rating is what you are');
    final down = Rating(mu: before.mu - 30, phi: 60);
    await show(down);
    expect(_colourOf(tester, '${down.shown - before.shown}'), Palette.danger);
  });

  testWidgets('the rating on your profile is what you are, not something to press', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const stats = PlayerStats(
      rating: Rating(mu: 1600, phi: 60),
      ratedGames: 30,
      live: Tally(games: 30, won: 9, points: 30 * 40, best: 18),
      alone: Tally(games: 4, won: 2, points: 4 * 44, best: 21),
      reached: true,
    );
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: ProfilePage(current: (name: 'Ada', avatar: Avatar.none), seed: 'k1', stats: Stream.value(stats)),
    ));
    await tester.pumpAndSettle();
    expect(_colourOf(tester, '${stats.rating!.shown}'), Palette.chrome);
  });

  testWidgets('a trick that has been taken is news; the turn to play is gold', (tester) async {
    // Played out with the pointer on a paced table, which is the only
    // way the pill and the badge are both on screen at once.
    await pumpTable(tester, paced: true);
    final hand = fanCards(tester);
    for (var i = 0; i < 3; i++) {
      await tapCard(tester, hand[i].card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    await tester.pumpAndSettle();

    // Four cards down, and the pill says who took it.
    var pill = find.textContaining(RegExp(r'take(s)? it'));
    for (var guard = 0; guard < 60 && pill.evaluate().isEmpty; guard++) {
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
      await tester.pump(const Duration(milliseconds: 300));
      pill = find.textContaining(RegExp(r'take(s)? it'));
    }
    expect(pill, findsOneWidget, reason: 'a trick was taken');
    final said = tester.widget<Text>(pill).data!;
    final tone = tester.widget<Text>(pill).style!.color!;
    expect(tone, said.contains('·') ? Palette.danger : Palette.chrome,
        reason: 'points are the game\'s own red; a trick worth nothing is just news');
    expect(tone, isNot(Palette.gold));
    // The table paces itself with timers; taking the page away is what
    // cancels them, and a test that left one running would fail on its
    // way out for a reason that has nothing to do with colour.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
