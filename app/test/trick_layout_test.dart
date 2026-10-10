/// The trick on a phone held upright: its cards the size of the hand's,
/// and laid out so that none covers another's corner, where its rank and
/// suit are, whichever cards are down.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/table_model.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/table_view.dart';

/// Where a card's rank and suit are: its top left, a little over a
/// third of its width and under half its height.
Rect corner(Rect card) => Rect.fromLTWH(card.left, card.top, card.width * 0.36, card.height * 0.45);

void main() {
  // The iPhones of the last few years and an SE, and one in a Home Screen
  // web app, whose status bar the page does not get; and the 360-point
  // width most Android phones have.
  for (final size in const [
    Size(360, 780),
    Size(360, 800),
    Size(375, 667),
    Size(390, 844),
    Size(393, 852),
    Size(402, 874),
    Size(402, 812),
    Size(430, 932),
    Size(440, 956),
  ]) {
    testWidgets('at ${size.width.toInt()}x${size.height.toInt()}: the hand\'s size, and every corner in sight', (tester) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const TablePage(seed: 156, paced: true),
      ));
      await tester.pump(const Duration(seconds: 2));
      final TableModel c = tester.widget<TableView>(find.byType(TableView)).controller;
      for (final card in c.handShown.take(engine.passSize)) {
        c.toggleSelected(card);
      }
      c.confirmPass();
      final felt = find.descendant(of: find.byType(TableView), matching: find.byType(CardView));
      // Played by the first legal card until all four of a trick are down.
      var four = <Rect>[];
      for (var t = 0; t < 2000 && four.isEmpty; t++) {
        if (c.awaitingPlay) c.playCard(c.handShown.firstWhere(c.legalNow.contains));
        await tester.pump(const Duration(milliseconds: 50));
        List<Rect> rects() => felt.evaluate().map((e) => tester.getRect(find.byWidget(e.widget))).toList();
        // Landed: the last card's flight in is over, and the trick holds
        // still between two looks.
        if (rects().length == 4) {
          await tester.pump(const Duration(milliseconds: 60));
          final a = rects();
          await tester.pump(const Duration(milliseconds: 16));
          final b = rects();
          if (a.length == 4 && b.length == 4 && List.generate(4, (i) => a[i] == b[i]).every((same) => same)) four = b;
        }
      }
      expect(four, hasLength(4), reason: 'a whole trick on the felt');

      final hand = find.descendant(of: find.byType(HandFan), matching: find.byType(CardView));
      final handWidth = tester.getSize(hand.first).width;
      for (final r in four) {
        expect(r.width, moreOrLessEquals(handWidth, epsilon: 0.5), reason: 'a card on the felt is a card in the hand');
      }
      // In the order the trick draws them: south, west, north, east.
      final byY = [...four]..sort((a, b) => a.center.dy.compareTo(b.center.dy));
      final north = byY.first, south = byY.last;
      final middle = [byY[1], byY[2]]..sort((a, b) => a.center.dx.compareTo(b.center.dx));
      final drawn = [south, middle.first, north, middle.last];
      for (var below = 0; below < 4; below++) {
        for (var above = below + 1; above < 4; above++) {
          expect(drawn[above].overlaps(corner(drawn[below]).deflate(0.5)), isFalse,
              reason: 'card ${['south', 'west', 'north', 'east'][above]} over ${['south', 'west', 'north', 'east'][below]}\'s corner');
        }
      }
      // A pinwheel: north stepped to the west, south to the east.
      expect(north.center.dx, lessThan(south.center.dx));
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
