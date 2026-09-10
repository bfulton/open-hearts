/// The table, driven the way a thumb drives it.
///
/// These go through the widgets on purpose: the engine tests already
/// prove the rules, so what is left to prove is that a tap reaches them
/// and that the screen says what just happened.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' as engine;
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:open_hearts/theme.dart';

/// A phone-shaped surface: the fan layout is the part most likely to
/// break, and it only breaks when width is scarce.
const _phone = Size(390, 844);

Future<void> pumpTable(WidgetTester tester, {int seed = 4}) async {
  tester.view
    ..physicalSize = _phone
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: TablePage(seed: seed, paced: false),
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

/// Taps a card the way a thumb does: on the sliver it actually shows.
///
/// The fan overlaps left to right with later cards on top, so a card's
/// centre belongs to its right-hand neighbour and only the left edge is
/// its own. tester.tap() aims at the centre, which would quietly play
/// the wrong card — the same mistake a fat tap makes on a phone.
Future<void> tapCard(WidgetTester tester, engine.Card card) async {
  final finder = cardFinder(card);
  final topLeft = tester.getTopLeft(finder);
  final size = tester.getSize(finder);
  await tester.tapAt(Offset(topLeft.dx + 5, topLeft.dy + size.height / 2));
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

  testWidgets('the running build is stamped on the table', (tester) async {
    await pumpTable(tester);
    expect(find.text('dev'), findsOneWidget);
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
