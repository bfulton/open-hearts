/// The table, driven the way a thumb drives it.
///
/// These go through the widgets on purpose: the engine tests already
/// prove the rules, so what is left to prove is that a tap reaches them
/// and that the screen says what just happened.
library;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' as engine;
import 'package:open_hearts/about_page.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/header.dart';
import 'package:open_hearts/ui/table_layout.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:open_hearts/theme.dart';

/// A phone-shaped surface: the fan layout is the part most likely to
/// break, and it only breaks when width is scarce.
const _phone = Size(390, 844);

/// The same phone on its side: height is what is scarce there, and the
/// composition is a different one (docs/05-form-factors.md).
const _sideways = Size(844, 390);

Future<void> pumpTable(WidgetTester tester, {int seed = 4, Size size = _phone, bool paced = false}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: TablePage(seed: seed, paced: paced),
  ));
  await tester.pumpAndSettle();
}

/// The card widgets currently in the player's fan, left to right.
/// Scoped to the fan: cards on the table are CardViews too.
List<CardView> fanCards(WidgetTester tester) => tester
    .widgetList<CardView>(find.descendant(
      of: find.byType(HandFan),
      matching: find.byType(CardView),
    ))
    .toList();

Finder cardFinder(engine.Card card) => find.descendant(
    of: find.byType(HandFan),
    matching: find.byWidgetPredicate((w) => w is CardView && w.card == card));

/// Where a thumb lands on a card: on the sliver it actually shows.
///
/// The fan overlaps left to right with later cards on top, so a card's
/// centre belongs to its right-hand neighbour and only the left edge is
/// its own. tester.tap() aims at the centre, which would quietly play
/// the wrong card — the same mistake a fat tap makes on a phone.
Offset sliverOf(WidgetTester tester, engine.Card card) {
  final finder = cardFinder(card);
  final topLeft = tester.getTopLeft(finder);
  final size = tester.getSize(finder);
  return Offset(topLeft.dx + 5, topLeft.dy + size.height / 2);
}

/// Taps a card the way a thumb does.
Future<void> tapCard(WidgetTester tester, engine.Card card) async {
  await tester.tapAt(sliverOf(tester, card));
  await tester.pumpAndSettle();
}

/// Drags a card up by [dy] points and lets go.
Future<void> dragCard(WidgetTester tester, engine.Card card, double dy) async {
  await tester.dragFrom(sliverOf(tester, card), Offset(0, -dy));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the pass, asking for three cards', (tester) async {
    await pumpTable(tester);
    expect(find.textContaining('Choose 3 more to pass'), findsOneWidget);
    expect(find.text('Pass'), findsOneWidget);
    expect(find.text('Hand 1  ·  Pass left  ·  to 100'), findsOneWidget);
  });

  testWidgets('the Pass button waits for exactly three cards', (tester) async {
    await pumpTable(tester);
    final pass = find.widgetWithText(FilledButton, 'Pass');
    expect(tester.widget<FilledButton>(pass).onPressed, isNull);

    final hand = fanCards(tester);
    for (var i = 0; i < 3; i++) {
      await tapCard(tester, hand[i].card);
    }
    expect(find.text('Pass left'), findsOneWidget);
    expect(tester.widget<FilledButton>(pass).onPressed, isNotNull);

    // Un-picking one closes the button again.
    await tapCard(tester, hand[0].card);
    expect(find.textContaining('Choose 1 more'), findsOneWidget);
    expect(tester.widget<FilledButton>(pass).onPressed, isNull);
  });

  testWidgets('a fourth pick is refused rather than swapping one out',
      (tester) async {
    await pumpTable(tester);
    final hand = fanCards(tester);
    for (var i = 0; i < 4; i++) {
      await tapCard(tester, hand[i].card);
    }
    final selected = fanCards(tester).where((c) => c.selected).length;
    expect(selected, 3);
  });

  testWidgets('passing deals into play and names what you were given',
      (tester) async {
    await pumpTable(tester);
    final hand = fanCards(tester);
    for (var i = 0; i < 3; i++) {
      await tapCard(tester, hand[i].card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    await tester.pumpAndSettle();

    expect(find.text('Pass'), findsNothing);
    // Hand 1 passes left, so seat 0 receives from seat 3 — East, drawn
    // on the right, so the arrow points right.
    final names = tester.widget<TableView>(find.byType(TableView)).controller.names;
    expect(find.text('${names[3]} passed you'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    // Thirteen again: three left, three arrived.
    expect(fanCards(tester).length, 13);
  });

  testWidgets('tapping an illegal card explains the rule instead of playing it',
      (tester) async {
    await pumpTable(tester);
    final state = tester.state(find.byType(TablePage));
    await _passAnything(tester);

    // Run the bots up to the player's turn, then find a dimmed card.
    await tester.pumpAndSettle();
    final dimmed = fanCards(tester).where((c) => c.dimmed).toList();
    expect(dimmed, isNotEmpty,
        reason: 'the first trick always forbids something');
    await tapCard(tester, dimmed.first.card);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(fanCards(tester).length, greaterThan(0));
    expect(state.mounted, isTrue);
  });

  testWidgets('a legal tap plays the card onto the table', (tester) async {
    await pumpTable(tester);
    await _passAnything(tester);
    await tester.pumpAndSettle();

    final before = fanCards(tester);
    final playable = before.firstWhere((c) => !c.dimmed);
    await tapCard(tester, playable.card);

    expect(fanCards(tester).length, before.length - 1,
        reason: 'the card left the hand');
  });

  testWidgets('playable cards are told apart by brightness, not by lifting', (tester) async {
    await pumpTable(tester);
    await _passAnything(tester);
    await tester.pumpAndSettle();
    final cards = fanCards(tester);
    final playable = cards.firstWhere((c) => !c.dimmed);
    final dimmed = cards.firstWhere((c) => c.dimmed);
    expect(tester.getTopLeft(cardFinder(playable.card)).dy, tester.getTopLeft(cardFinder(dimmed.card)).dy,
        reason: 'the whole hand sits on one line');
  });

  testWidgets('a card dragged up towards the table is played; dragged a little, it drops back', (tester) async {
    await pumpTable(tester);
    await _passAnything(tester);
    await tester.pumpAndSettle();
    final before = fanCards(tester);
    final playable = before.firstWhere((c) => !c.dimmed);
    final height = cardHeightFor(playable.width);
    final threshold = height * HandFan.dragToPlay;
    expect(threshold, greaterThan(kTouchSlop), reason: 'a drag short of it is a drag, not a wobbly tap');
    // A finger's first few points of travel are what make it a drag
    // rather than a tap, and the card does not move for them.
    const slop = kDragSlopDefault;

    // A drag, but short of a third of the card's height: it drops back.
    await dragCard(tester, playable.card, slop + threshold - 8);
    expect(fanCards(tester).length, before.length);
    expect(fanCards(tester).map((c) => c.card), contains(playable.card));

    // Under the finger the card follows it, up out of the row.
    final resting = tester.getTopLeft(cardFinder(playable.card)).dy;
    final finger = await tester.startGesture(sliverOf(tester, playable.card));
    await finger.moveBy(const Offset(0, -slop));
    await finger.moveBy(const Offset(0, -25));
    await tester.pump();
    expect(tester.getTopLeft(cardFinder(playable.card)).dy, closeTo(resting - 25, 0.5));
    await finger.moveBy(const Offset(0, 25));
    await finger.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(cardFinder(playable.card)).dy, closeTo(resting, 0.5), reason: 'let go where it started, it stays');
    expect(fanCards(tester).length, before.length);

    // Past it: played, the same as a tap.
    await dragCard(tester, playable.card, slop + threshold + 6);
    expect(fanCards(tester).length, before.length - 1, reason: 'the card left the hand');
    expect(fanCards(tester).map((c) => c.card), isNot(contains(playable.card)));
  });

  testWidgets('a card dragged up during the pass is picked, and lifts', (tester) async {
    await pumpTable(tester);
    final hand = fanCards(tester);
    final restingTop = tester.getTopLeft(cardFinder(hand[0].card)).dy;
    await dragCard(tester, hand[0].card, kDragSlopDefault + cardHeightFor(hand[0].width) * HandFan.dragToPlay + 6);
    expect(fanCards(tester).firstWhere((c) => c.card == hand[0].card).selected, isTrue);
    expect(find.textContaining('Choose 2 more'), findsOneWidget);
    expect(tester.getTopLeft(cardFinder(hand[0].card)).dy, lessThan(restingTop), reason: 'a picked card lifts');
  });

  testWidgets('while the others choose, the three passed are off the hand and on the line', (tester) async {
    // Paced: the bots take their time, so there is a moment to look.
    await pumpTable(tester, paced: true);
    final hand = fanCards(tester);
    final chosen = [for (var i = 0; i < 3; i++) hand[i].card];
    for (final card in chosen) {
      await tapCard(tester, card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    await tester.pump();

    expect(fanCards(tester).length, 10, reason: 'the three are gone from the hand');
    for (final card in chosen) {
      expect(cardFinder(card), findsNothing);
      expect(find.bySemanticsLabel(card.spoken), findsOneWidget, reason: 'and on the line');
    }
    final names = tester.widget<TableView>(find.byType(TableView)).controller.names;
    // Hand 1 passes left: to seat 1, drawn on the left.
    expect(find.text('Passed to ${names[1]}'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // The bots pass and play up to the player's turn: thirteen again.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('Passed to ${names[1]}'), findsNothing);
    expect(fanCards(tester).length, greaterThanOrEqualTo(12));
  });

  testWidgets('a whole hand plays out to the score sheet', (tester) async {
    await pumpTable(tester);
    await _passAnything(tester);

    for (var guard = 0; guard < 60; guard++) {
      await tester.pumpAndSettle();
      if (find.text('Next hand').evaluate().isNotEmpty) break;
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isEmpty) continue;
      await tapCard(tester, playable.first.card);
    }

    expect(find.text('Next hand'), findsOneWidget);
    // Every seat is on the sheet: the player, and three named bots.
    expect(find.text('You'), findsWidgets);
    final seated = engine.Persona.roster.where((p) => find.text(p.name).evaluate().isNotEmpty);
    expect(seated.length, 3, reason: 'three of the roster are at the table');

    await tester.tap(find.text('Next hand'));
    await tester.pumpAndSettle();
    expect(find.text('Hand 2  ·  Pass right  ·  to 100'), findsOneWidget);
  });

  testWidgets('the hand fan fits a phone without overflowing', (tester) async {
    await pumpTable(tester);
    // A layout overflow is an exception in a test binding, so reaching
    // here at all is most of the assertion; the rest guards the numbers.
    expect(tester.takeException(), isNull);
    final cards = fanCards(tester);
    expect(cards.length, 13);
    for (final c in cards) {
      expect(c.width, greaterThanOrEqualTo(30.0));
      expect(cardHeightFor(c.width), lessThanOrEqualTo(128.0));
    }
  });

  testWidgets('the header: the menu on the left, the heart on the right, whole until hearts break', (tester) async {
    await pumpTable(tester);
    final header = tester.getRect(find.byType(TableHeader));
    expect(header.top, 0);
    expect(tester.getCenter(find.byIcon(Icons.menu)).dx, lessThan(_phone.width / 4));
    expect(tester.getCenter(find.byIcon(Icons.favorite)).dx, greaterThan(_phone.width * 3 / 4));
    expect(find.byIcon(Icons.heart_broken), findsNothing);
    expect(find.text('Hearts not broken'), findsNothing, reason: 'the heart says it, not a line of text');

    // Play until a heart is taken.
    await _passAnything(tester);
    for (var guard = 0; guard < 60 && !tester.widget<TableView>(find.byType(TableView)).controller.game.heartsBroken; guard++) {
      await tester.pumpAndSettle();
      if (find.text('Next hand').evaluate().isNotEmpty) break;
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isEmpty) continue;
      await tapCard(tester, playable.first.card);
    }
    if (tester.widget<TableView>(find.byType(TableView)).controller.game.heartsBroken) {
      expect(find.byIcon(Icons.heart_broken), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsNothing);
      expect(find.text('Hearts are broken'), findsNothing);
    }
  });

  testWidgets('the menu leaves the table, and names the build on the About page', (tester) async {
    // Pushed from a front door, as the app does it, so leaving has
    // somewhere to go.
    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TablePage(seed: 4, paced: false))),
          child: const Text('Play alone'),
        ),
      ),
    ));
    await tester.tap(find.text('Play alone'));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Leave the table'), findsOneWidget);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('dev'), findsWidgets, reason: 'the build tag, and its date');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave the table'));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsNothing);
    expect(find.text('Play alone'), findsOneWidget);
  });

  testWidgets('everyone\'s standing: the others\' on their badges, yours under the felt, no card counts', (tester) async {
    await pumpTable(tester);
    final model = tester.widget<TableView>(find.byType(TableView)).controller;
    for (var seat = 1; seat < engine.seatCount; seat++) {
      expect(find.bySemanticsLabel('${model.names[seat]}: 0 in the game, 0 this hand'), findsOneWidget);
    }
    expect(find.bySemanticsLabel(RegExp(r'\d+ cards')), findsNothing);
    expect(find.bySemanticsLabel('You: 0 in the game, 0 this hand'), findsOneWidget);
    final mine = tester.getRect(find.bySemanticsLabel('You: 0 in the game, 0 this hand'));
    final felt = tester.getRect(find.byType(TableView));
    final hand = tester.getRect(find.byType(HandFan));
    expect(mine.top, greaterThanOrEqualTo(felt.bottom));
    expect(mine.bottom, lessThanOrEqualTo(hand.top));
  });

  testWidgets('sideways, the same header, a shorter and wider hand', (tester) async {
    await pumpTable(tester, size: _sideways);
    expect(tester.takeException(), isNull);
    expect(find.text('Hand 1  ·  Pass left  ·  to 100'), findsOneWidget);
    expect(tester.getRect(find.byType(TableHeader)).width, _sideways.width);
    // Thirteen cards, each shorter than the portrait hand allows and
    // showing more of itself than the portrait fan can.
    final cards = fanCards(tester);
    expect(cards.length, 13);
    for (final c in cards) {
      expect(cardHeightFor(c.width), lessThanOrEqualTo(TableLayout.landscapeHandHeight));
    }
    final lefts = [for (final c in cards) tester.getTopLeft(cardFinder(c.card)).dx];
    final step = lefts[1] - lefts[0];
    expect(step, greaterThan(cards.first.width * 0.64), reason: 'a wider step than the portrait fan ever takes');
    // The hand keeps the bottom edge.
    expect(tester.getRect(find.byType(HandFan)).bottom, closeTo(_sideways.height - 8, 1));
  });

  testWidgets('turning the phone mid-hand keeps the game', (tester) async {
    await pumpTable(tester);
    await _passAnything(tester);
    final playable = fanCards(tester).firstWhere((c) => !c.dimmed);
    await tapCard(tester, playable.card);
    final hand = fanCards(tester).map((c) => c.card).toList();
    expect(hand.length, 12);
    final strip = find.text('Hand 1  ·  Pass left  ·  to 100');
    expect(strip, findsOneWidget);
    // The game as the table holds it: the same controller, with the
    // same tricks and the same trick under way, on both sides of a turn.
    final model = tester.widget<TableView>(find.byType(TableView)).controller;
    final tricks = model.game.tricksPlayed;
    final trick = model.game.trick.map((p) => p.card).toList();
    final totals = model.game.totals;

    // Sideways: the same game, a shorter hand.
    tester.view.physicalSize = _sideways;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(fanCards(tester).map((c) => c.card).toList(), hand);
    final turned = tester.widget<TableView>(find.byType(TableView)).controller;
    expect(identical(turned, model), isTrue, reason: 'the turn rebuilt the layout, not the game');
    expect(turned.game.tricksPlayed, tricks);
    expect(turned.game.trick.map((p) => p.card).toList(), trick);
    expect(turned.game.totals, totals);
    expect(strip, findsOneWidget);
    expect(tester.getRect(find.byType(HandFan)).height, lessThanOrEqualTo(TableLayout.landscapeHandHeight));

    // And back.
    tester.view.physicalSize = _phone;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(fanCards(tester).map((c) => c.card).toList(), hand);
    expect(identical(tester.widget<TableView>(find.byType(TableView)).controller, model), isTrue);
    expect(strip, findsOneWidget);
    expect(tester.getRect(find.byType(HandFan)).height, greaterThan(TableLayout.landscapeHandHeight));
  });

  testWidgets('a whole hand plays out sideways too', (tester) async {
    await pumpTable(tester, size: _sideways);
    await _passAnything(tester);
    for (var guard = 0; guard < 60; guard++) {
      await tester.pumpAndSettle();
      if (find.text('Next hand').evaluate().isNotEmpty) break;
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isEmpty) continue;
      await tapCard(tester, playable.first.card);
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Next hand'), findsOneWidget);
    await tester.tap(find.text('Next hand'));
    await tester.pumpAndSettle();
    expect(find.text('Hand 2  ·  Pass right  ·  to 100'), findsOneWidget);
  });
}

/// Picks the first three cards and passes them.
Future<void> _passAnything(WidgetTester tester) async {
  if (find.text('Pass').evaluate().isEmpty) return; // a hold hand
  final hand = fanCards(tester);
  for (var i = 0; i < 3; i++) {
    await tapCard(tester, hand[i].card);
  }
  await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
  await tester.pumpAndSettle();
}
