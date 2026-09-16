/// The third composition, and the two things a foldable has to hold
/// (docs/05-form-factors.md).
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
import 'package:open_hearts/ui/gone.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/table_layout.dart';

import 'table_page_test.dart' show fanCards, pumpTable, tapCard;

const _phone = Size(390, 844);
const _phoneSide = Size(844, 390);
/// Half of a 7.6″ inner display in portrait: narrower than any phone.
const _split = Size(340, 720);
const _tabletTall = Size(1024, 1366);
const _tabletWide = Size(1366, 1024);
const _desktop = Size(1600, 1000);

/// Where the hand fan sits, and how wide it is drawn.
Rect _fan(WidgetTester tester) => tester.getRect(find.byType(HandFan));

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
