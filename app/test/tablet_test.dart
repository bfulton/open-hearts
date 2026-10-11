/// The third composition, and the two things a foldable has to hold
/// (docs/explanation/screens.md).
///
/// A tablet is not a big phone. The felt already stops growing its
/// cards, so all a wider screen buys is emptier felt and a fan spread so
/// far that you reach across the device to touch your own hand. Past a
/// width the table wants, it holds that width, and what is left over is
/// a rail carrying what a phone has to hide.
///
/// Every shape here is read off the constraints, never off a device: a
/// phone turning, a window dragged narrower, a foldable opening and a
/// tablet in Split View are one event, handled once.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/gone.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/scaled.dart';
import 'package:open_hearts/ui/table_layout.dart';
import 'package:open_hearts/ui/table_view.dart';

import 'drawn.dart';
import 'table_page_test.dart' show cardFinder, fanCards, pumpTable, tapCard;

const _phone = Size(390, 844);
const _phoneSide = Size(844, 390);
/// Half of a 7.6″ inner display in portrait: narrower than any phone.
const _split = Size(340, 720);
const _tabletTall = Size(1024, 1366);
const _tabletWide = Size(1366, 1024);
const _desktop = Size(1600, 1000);

/// Where the hand fan sits, and how wide it is drawn.
Rect _fan(WidgetTester tester) => tester.getRect(find.byType(HandFan));

/// How much bigger [finder] is drawn than it is laid out.
double _drawnAt(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return tester.getRect(finder).width / box.size.width;
}

/// The table's scale, as the layout gave it.
double _scale(WidgetTester tester) => tester.widget<TableScale>(find.byType(TableScale)).scale;

/// Where the cards of the fan run from and to.
(double, double) _fanSpan(WidgetTester tester) {
  final rects = [for (final c in fanCards(tester)) tester.getRect(cardFinder(c.card))];
  return (
    rects.map((r) => r.left).reduce((a, b) => a < b ? a : b),
    rects.map((r) => r.right).reduce((a, b) => a > b ? a : b),
  );
}

Future<void> resize(WidgetTester tester, Size to) async {
  tester.view.physicalSize = to;
  await tester.pumpAndSettle();
}

void main() {
  group('the layout decides from the room it has', () {
    test('a table holds its width once it has more than it wants', () {
      expect(TableLayout.isRoomy(const BoxConstraints(maxWidth: 390, maxHeight: 844)), isFalse);
      expect(TableLayout.isRoomy(const BoxConstraints(maxWidth: 844, maxHeight: 390)), isFalse,
          reason: 'a landscape phone is as wide as a table wants to be');
      expect(TableLayout.isRoomy(const BoxConstraints(maxWidth: 1024, maxHeight: 1366)), isTrue);
    });

    test('a rail takes what is left over, between worth having and worth widening', () {
      expect(TableLayout.railFor(844), 0, reason: 'a phone has nothing left over');
      expect(TableLayout.railFor(1024), 0, reason: 'and neither has a tablet in portrait, quite');
      expect(TableLayout.railFor(TableLayout.tableWidth + TableLayout.railLeast - 1), 0);
      expect(TableLayout.railFor(TableLayout.tableWidth + TableLayout.railLeast), TableLayout.railLeast);
      expect(TableLayout.railFor(1366), 420, reason: 'a tablet in landscape has a rail');
      expect(TableLayout.railFor(4000), TableLayout.railMost, reason: 'and a wall does not get a wider one');
    });
  });

  group('the table on a tablet', () {
    testWidgets('holds its width rather than spreading, and the hand stays near the thumbs', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _phoneSide);
      final onPhone = _fan(tester);
      expect(onPhone.width, lessThanOrEqualTo(844));

      await resize(tester, _tabletWide);
      final onTablet = _fan(tester);
      expect(onTablet.width, lessThanOrEqualTo(TableLayout.tableWidth),
          reason: 'a fan you would reach across the device to touch is not a hand');
      expect(onTablet.width, greaterThan(400), reason: 'and it still fills the table it is under');
    });

    testWidgets('puts what a phone has to hide in the room left over', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _phone);
      expect(find.byType(Gone), findsNothing, reason: 'a phone has no room for it');

      await resize(tester, _tabletWide);
      expect(find.byType(Gone), findsOneWidget);
      expect(find.text('What has gone'), findsOneWidget);
      // Nothing on it is a secret: it is the cards played face up.
      expect(find.textContaining('still out'), findsOneWidget);

      await resize(tester, _tabletTall);
      expect(find.byType(Gone), findsNothing, reason: 'a tablet in portrait is a wide table, not a table with a rail');
    });

    testWidgets('draws its type at the scale its cards grew by, and a phone\'s at exactly one', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _phone);
      expect(_scale(tester), 1.0);
      expect(tester.widgetList<Scaled>(find.byType(Scaled)).every((s) => s.scale == 1.0), isTrue,
          reason: 'a phone\'s table is drawn exactly as it was');

      await resize(tester, _tabletTall);
      final scale = _scale(tester);
      expect(scale, closeTo(TableScale.mostCard / TableScale.phoneCard, 1e-9),
          reason: 'a tablet\'s cards are as big as cards get');
      final names = tester.widget<TableView>(find.byType(TableView)).controller.names;
      for (final seat in names.skip(1)) {
        expect(_drawnAt(tester, drawn(find.text(seat))), closeTo(scale, 1e-6), reason: '$seat, at the table\'s scale');
      }
      expect(_drawnAt(tester, find.text('Choose 3 more to pass')), closeTo(scale, 1e-6));
      expect(_drawnAt(tester, find.widgetWithText(FilledButton, 'Pass')), closeTo(scale, 1e-6));

      // The cards on the felt grew by the same: the first one played
      // is at the most a card can be.
      final hand = fanCards(tester);
      for (var i = 0; i < 3; i++) {
        await tapCard(tester, hand[i].card);
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
      await tester.pumpAndSettle();
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
      await tester.pumpAndSettle();
      final onFelt = find.descendant(of: find.byType(TableView), matching: find.byType(CardView));
      expect(onFelt, findsWidgets);
      for (final card in onFelt.evaluate()) {
        expect(tester.getRect(find.byWidget(card.widget)).width, closeTo(TableScale.phoneCard * scale, 0.01));
      }

      // And the rail, where there is one.
      await resize(tester, _tabletWide);
      expect(_drawnAt(tester, find.text('What has gone')), closeTo(_scale(tester), 1e-6));
      expect(tester.takeException(), isNull);
    });

    testWidgets('and its rail are centred as one, with the same margin either side', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _desktop);
      final table = tester.getRect(find.byType(TableScale));
      final rail = tester.getRect(find.byType(Gone));
      expect(table.width, TableLayout.tableWidth);
      expect(rail.left, closeTo(table.right, 0.01), reason: 'the rail is beside the table');
      expect(table.left, greaterThan(0), reason: 'a desktop has room to spare');
      expect(_desktop.width - rail.right, closeTo(table.left, 0.01));
    });

    testWidgets('the action line spans the hand it is about, at every shape', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _phone);
      for (final shape in [_phone, _phoneSide, _split, _tabletTall, _tabletWide, _desktop]) {
        await resize(tester, shape);
        final (left, right) = _fanSpan(tester);
        final note = tester.getRect(find.text('Choose 3 more to pass'));
        final pass = tester.getRect(find.widgetWithText(FilledButton, 'Pass'));
        // The line is a whole hand's width and a margin, and keeps its
        // own padding inside that: its ends sit just inside the fan's,
        // give or take the gap a missing suit leaves out of this hand.
        expect((note.left - left).abs(), lessThan(30), reason: '$shape: the note starts where the hand does');
        expect((right - pass.right).abs(), lessThan(30), reason: '$shape: the Pass button ends where the hand does');
      }
    });

    testWidgets('the rail says which cards have gone, and keeps up as they go', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _desktop);
      expect(find.text('13 hearts and the queen still out'), findsOneWidget, reason: 'nothing has gone before the pass');

      final hand = fanCards(tester);
      for (var i = 0; i < 3; i++) {
        await tapCard(tester, hand[i].card);
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
      await tester.pumpAndSettle();
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
      await tester.pumpAndSettle();

      // The first trick is four clubs, so the count of hearts has not
      // moved and the queen is still out — but cards have gone, and the
      // rail is looking at the same set the table is.
      final rail = tester.widget<Gone>(find.byType(Gone));
      expect(rail.played, isNotEmpty);
      expect(rail.played.every((c) => c.suit != engine.Suit.hearts), isTrue);
      expect(find.text('13 hearts and the queen still out'), findsOneWidget);
    });
  });

  group('a foldable', () {
    testWidgets('unfolding mid-hand keeps the game: the same hand, trick and totals', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Closed, a Duo is a phone. Play into the hand first.
      await pumpTable(tester, size: _phone);
      final hand = fanCards(tester);
      for (var i = 0; i < 3; i++) {
        await tapCard(tester, hand[i].card);
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
      await tester.pumpAndSettle();
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
      await tester.pumpAndSettle();
      final before = fanCards(tester).map((c) => c.card.code).toList();
      expect(before, isNotEmpty);

      // Open: the inner display is the same shape, larger. A resize
      // must never cost state — the usual way this breaks is a widget
      // rebuilding its controller when the constraints change.
      await resize(tester, _tabletTall);
      expect(fanCards(tester).map((c) => c.card.code).toList(), before, reason: 'the same hand across the fold');

      // And folding it back again.
      await resize(tester, _phone);
      expect(fanCards(tester).map((c) => c.card.code).toList(), before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Split View is the narrowest thing there is, and it is the phone composition', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpTable(tester, size: _split);
      expect(find.byType(Gone), findsNothing);
      expect(_fan(tester).width, lessThanOrEqualTo(340));
      // Thirteen cards still fan across it, which is the whole argument
      // for sizing from constraints: half a tablet is narrower than any
      // phone, and nothing here knows what a tablet is.
      expect(fanCards(tester).length, 13);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('every shape lays out without overflowing', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpTable(tester, size: _phone);
    for (final shape in [_phone, _phoneSide, _split, _tabletTall, _tabletWide, _desktop]) {
      await resize(tester, shape);
      expect(tester.takeException(), isNull, reason: '$shape');
      expect(find.byType(HandFan), findsOneWidget, reason: '$shape');
    }
  });
}
