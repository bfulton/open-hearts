/// The profile as a page: who you are at the top, and what the games
/// say under it.
///
/// The rating is the live games' alone, so a device that has played
/// none of them has none to show — and says so, rather than showing
/// the number everyone starts at as though it had been earned.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/player_icon.dart';
import 'package:table/table.dart';

const _phone = Size(390, 844);

Future<void> pumpProfile(WidgetTester tester, Stream<PlayerStats> stats, {String name = 'Ada'}) async {
  tester.view
    ..physicalSize = _phone
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: ProfilePage(current: (name: name, avatar: Avatar.none), seed: 'k1', stats: stats),
  ));
  await tester.pumpAndSettle();
}

/// Where [text]'s letters are drawn: a table's cell gives its text the
/// cell's width, so the box says where the cell is, not the figures.
Rect _inked(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: paragraph.text.toPlainText().length));
  final rect = boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
  return rect.shift(paragraph.localToGlobal(Offset.zero));
}

void main() {
  testWidgets('a rating, and both halves of the game', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(
        rating: Rating(mu: 1622, phi: 60),
        ratedGames: 9,
        live: Tally(games: 12, won: 4, points: 12 * 38, best: 19),
        alone: Tally(games: 30, won: 11, points: 30 * 41, best: 26),
        reached: true,
      )),
    );

    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('1622'), findsOneWidget);
    expect(find.textContaining('From 9 games'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Alone'), findsOneWidget);
    // played / won / average, for each half.
    expect(find.text('12'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('38'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('11'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('19'), findsOneWidget, reason: 'the best live game');
    expect(find.text('26'), findsOneWidget, reason: 'and the best alone');
  });

  testWidgets('no rated games, no rating — and it says which', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(
        rating: Rating.fresh,
        alone: Tally(games: 3, won: 1, points: 150),
        reached: true,
      )),
    );
    expect(find.text('1500'), findsNothing, reason: 'the number everyone starts at is not a rating anyone earned');
    expect(find.text('—'), findsWidgets);
    expect(find.textContaining('Play a rated live game'), findsOneWidget);
    // The games played alone still stand: three of them, one won, at 50.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
  });

  testWidgets('a provisional rating says so, and a silent relay says that instead', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(rating: Rating(mu: 1480, phi: 300), ratedGames: 1, reached: true)),
    );
    expect(find.text('1480'), findsOneWidget);
    expect(find.textContaining('Provisional, from one game'), findsOneWidget);

    await pumpProfile(tester, Stream.value(const PlayerStats(alone: Tally(games: 2, won: 0, points: 80))));
    expect(find.textContaining('relays did not answer'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'what the device itself knows is still known');
  });

  testWidgets('each column of figures lines up under its name', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(
        rating: Rating(mu: 1622, phi: 60),
        ratedGames: 9,
        live: Tally(games: 112, won: 4, points: 112 * 38, best: 19),
        alone: Tally(games: 7, won: 3, points: 7 * 41, best: 26),
        reached: true,
      )),
    );
    Rect inked(String text) => _inked(tester, find.text(text));
    const live = ['Live', '112', '4', '38', '19'];
    const alone = ['Alone', '7', '3', '41', '26'];
    for (final column in [live, alone]) {
      for (final cell in column.skip(1)) {
        expect(inked(cell).right, closeTo(inked(column.first).right, 0.01), reason: '$cell, under ${column.first}');
      }
    }
    // What each line is, said once, down the left; the two columns
    // clear of it and of each other.
    final liveLeft = live.map((c) => inked(c).left).reduce((a, b) => a < b ? a : b);
    final aloneLeft = alone.map((c) => inked(c).left).reduce((a, b) => a < b ? a : b);
    for (final label in ['played', 'won', 'average', 'best']) {
      expect(find.text(label), findsOneWidget);
      expect(inked(label).right, lessThan(liveLeft), reason: label);
    }
    expect(inked('Live').right, lessThan(aloneLeft));
  });

  testWidgets('the icon and the colour you chose are ringed in white, clear of the disc', (tester) async {
    await pumpProfile(tester, Stream.value(const PlayerStats(reached: true)));
    final ringed = find.byWidgetPredicate((w) =>
        w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).border?.top.color == Palette.chrome);
    final gold = find.byWidgetPredicate((w) =>
        w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).border?.top.color == Palette.gold);
    // Your initials, on the colour your key gives you: that colour is
    // the choice so far, and no icon is.
    expect(ringed, findsOneWidget);

    // Choosing is the same on every colour, the one gold is nearest
    // among them.
    for (var i = 0; i < PlayerIcon.palette.length; i++) {
      for (final label in ['Colour ${i + 1}', 'Paw']) {
        await tester.ensureVisible(find.bySemanticsLabel(label));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel(label));
        await tester.pumpAndSettle();
      }
      expect(ringed, findsNWidgets(2), reason: 'the paw and colour ${i + 1}');
      expect(gold, findsNothing, reason: 'which one you chose is what a thing is, not something to do');
      for (final label in ['Paw', 'Colour ${i + 1}']) {
        final ring = find.descendant(of: find.bySemanticsLabel(label), matching: ringed);
        expect(ring, findsOneWidget, reason: label);
        final disc = find.descendant(
            of: ring,
            matching: find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).color != null));
        final width = (tester.widget<Container>(ring).decoration! as BoxDecoration).border!.top.width;
        final outer = tester.getRect(ring);
        final inner = tester.getRect(disc);
        expect(inner.left - outer.left, greaterThan(width), reason: '$label: felt between the ring and the disc');
        expect((tester.widget<DecoratedBox>(disc).decoration as BoxDecoration).color, PlayerIcon.palette[i]);
      }
    }
  });
}
