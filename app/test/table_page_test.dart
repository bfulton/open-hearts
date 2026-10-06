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
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/record_store.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/header.dart';
import 'package:open_hearts/ui/player_icon.dart';
import 'package:open_hearts/ui/table_layout.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/pages.dart';

import 'routes.dart';

import 'drawn.dart';

/// A phone-shaped surface: the fan layout is the part most likely to
/// break, and it only breaks when width is scarce.
const _phone = Size(390, 844);

/// The same phone on its side: height is what is scarce there, and the
/// composition is a different one (docs/05-form-factors.md).
const _sideways = Size(844, 390);

/// A second table in the same test needs a [key] of its own: the page
/// keeps its game across a rebuild, as it should.
Future<void> pumpTable(WidgetTester tester,
    {int seed = 4, Size size = _phone, bool paced = false, Key? key, int target = engine.gameOverScore}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: TablePage(key: key, seed: seed, paced: paced, target: target),
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

/// How much the badge's own scaling has shrunk a name on its way to
/// the screen: 1 when it is drawn at the size it asks for.
double _scaleOf(WidgetTester tester, Finder text) {
  final box = tester.renderObject<RenderBox>(text);
  final painted = tester.getRect(text);
  return box.size.width == 0 ? 1 : painted.width / box.size.width;
}

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
    expect(find.text('Hand 1  ·  Pass left  ·  to 50'), findsOneWidget);
  });

  testWidgets('a table asked for a hundred plays to a hundred, and the header says so', (tester) async {
    await pumpTable(tester, target: 100);
    expect(find.text('Hand 1  ·  Pass left  ·  to 100'), findsOneWidget);
    expect(tester.widget<TableHeader>(find.byType(TableHeader)).game.target, 100);
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

    // Past it: played, the same as a tap — and it carries on to the
    // table from where the finger let it go, rather than dropping back
    // into the row first.
    final carried = slop + threshold + 6;
    await tester.dragFrom(sliverOf(tester, playable.card), Offset(0, -carried));
    await tester.pump();
    expect(tester.getTopLeft(cardFinder(playable.card)).dy, lessThan(resting - threshold),
        reason: 'the played card leaves from the finger, not from the row');

    await tester.pumpAndSettle();
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
    final from = {for (final card in chosen) card: tester.getTopLeft(cardFinder(card))};
    for (final card in chosen) {
      await tapCard(tester, card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    await tester.pump();

    // They do not vanish: hand 1 passes left, so they go off the left
    // of the screen, the side the seat they are going to sits on.
    await tester.pump(const Duration(milliseconds: 250));
    for (final card in chosen) {
      final gone = tester.getTopLeft(cardFinder(card));
      expect(gone.dx, lessThan(from[card]!.dx - 60), reason: 'a passed card leaves towards its seat');
      expect(gone.dy, closeTo(from[card]!.dy, 1), reason: 'sideways, not up');
    }

    await tester.pumpAndSettle();
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

  testWidgets('the cards passed to the player come in from the side the passer sits on', (tester) async {
    // The fan on its own: the three arrive, and the hand they land in
    // is the same hand either way, so the only thing to see is the
    // journey. A pass to the left is received from the right.
    final held = [for (final c in '2C.3C.4C.5C'.split('.')) engine.Card.parse(c)];
    final given = [for (final c in 'AH.KH.QH'.split('.')) engine.Card.parse(c)];
    Widget fan(List<engine.Card> hand, Set<engine.Card> arrived) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: TableLayout.portraitHandHeight,
              child: HandFan(
                hand: hand,
                onTap: (_) {},
                justReceived: arrived,
                receivedFrom: const Offset(1, 0),
              ),
            ),
          ),
        );

    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fan(held, const {}));
    await tester.pumpWidget(fan([...held, ...given]..sort(), given.toSet()));
    await tester.pump(const Duration(milliseconds: 60));

    final flying = {for (final card in given) card: tester.getTopLeft(cardFinder(card)).dx};
    await tester.pumpAndSettle();
    for (final card in given) {
      expect(flying[card]!, greaterThan(tester.getTopLeft(cardFinder(card)).dx + 60),
          reason: 'an arriving card comes in from the passer\'s side');
    }
    for (final card in held) {
      expect(cardFinder(card), findsOneWidget, reason: 'the hand it lands in is whole');
    }
  });

  testWidgets('the last card of a hand is still seen leaving it', (tester) async {
    // The fan the card leaves behind is empty, which is the one place
    // the hand has nothing of its own left to draw.
    final last = engine.Card.parse('2C');
    Widget fan(List<engine.Card> hand) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: TableLayout.portraitHandHeight,
              child: HandFan(hand: hand, onTap: (_) {}),
            ),
          ),
        );

    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fan([last]));
    final was = tester.getTopLeft(cardFinder(last));
    await tester.pumpWidget(fan(const []));
    await tester.pump(const Duration(milliseconds: 120));

    expect(cardFinder(last), findsOneWidget, reason: 'still on its way');
    expect(tester.getTopLeft(cardFinder(last)).dy, lessThan(was.dy - 20), reason: 'rising towards the table');

    // And it left on the frame it was tapped. With a hand behind it the
    // fan closing over the gap is movement enough to cover a card that
    // takes a few frames to get going; the last card has nothing behind
    // it, so it is the one that shows a slow start.
    await tester.pumpWidget(fan([last]));
    await tester.pumpAndSettle();
    final resting = tester.getTopLeft(cardFinder(last)).dy;
    await tester.pumpWidget(fan(const []));
    // The first frame drawn after the tap, not the second: a flight
    // that starts from nothing spends this frame where the card
    // already was, and on the last card of a hand there is nothing
    // else moving to cover it.
    await tester.pump();
    expect(tester.getTopLeft(cardFinder(last)).dy, lessThan(resting - 20), reason: 'a tapped card has already moved');
    await tester.pumpAndSettle();
    expect(cardFinder(last), findsNothing, reason: 'and then gone');
  });

  testWidgets('a card played lands: solid a third of the way in, and down flat on the felt', (tester) async {
    await pumpTable(tester, paced: true);
    await _passAnything(tester);
    final controller = tester.widget<TableView>(find.byType(TableView)).controller;
    // A bot's card, the moment it is on the table.
    var before = controller.game.trick.length;
    engine.Card? card;
    for (var guard = 0; guard < 3000 && card == null; guard++) {
      await tester.pump(const Duration(milliseconds: 10));
      final now = controller.game.trick.length;
      if (now > before) card = controller.game.trick.last.card;
      before = now;
    }
    expect(card, isNotNull);
    final onFelt = find.descendant(
        of: find.byType(TableView), matching: find.byWidgetPredicate((w) => w is CardView && w.card == card));
    final width = tester.widget<CardView>(onFelt).width;
    double opacity() => tester.widget<Opacity>(find.ancestor(of: onFelt, matching: find.byType(Opacity)).first).opacity;

    await tester.pump(const Duration(milliseconds: 30));
    final early = tester.getRect(onFelt);
    expect(early.width, greaterThan(width + 1), reason: 'coming down onto the felt: a touch big and askew');
    await tester.pump(const Duration(milliseconds: 60));
    expect(opacity(), 1.0, reason: 'solid a third of the way in, not fading up the whole way');
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(onFelt).width, closeTo(width, 0.01), reason: 'and down flat, at its own size');
    expect(opacity(), 1.0);

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
  });

  testWidgets('the finished trick is gathered onto the card that took it, and taken', (tester) async {
    await pumpTable(tester, paced: true);
    await _passAnything(tester);
    final controller = tester.widget<TableView>(find.byType(TableView)).controller;
    for (var guard = 0; guard < 80 && controller.game.pendingTrick == null; guard++) {
      await tester.pump(const Duration(milliseconds: 100));
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (controller.awaitingPlay && playable.isNotEmpty) await tapCard(tester, playable.first.card);
    }
    final trick = controller.game.pendingTrick!;
    // Settled on the table, so the start is where the cards sit.
    for (var guard = 0; guard < 100 && controller.game.pendingTrick != null; guard++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final towards = seatDirection[controller.positionOf(trick.winner)]!;
    double along(Offset o) => o.dx * towards.dx + o.dy * towards.dy;
    final cards = [for (final play in trick.plays) play.card];
    var last = {for (final card in cards) card: along(_feltCentre(tester, card))};
    final spreads = <int, double>{};
    final opacities = <int, double>{};
    for (var ms = 10; ms <= 280; ms += 10) {
      await tester.pump(const Duration(milliseconds: 10));
      final centres = {for (final card in cards) card: _feltCentre(tester, card)};
      for (final card in cards) {
        expect(along(centres[card]!), greaterThanOrEqualTo(last[card]! - 0.01),
            reason: '$card only ever moves towards the seat that took it ($ms ms)');
        last[card] = along(centres[card]!);
      }
      final xs = centres.values.map((c) => c.dx);
      final ys = centres.values.map((c) => c.dy);
      spreads[ms] = (xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b)) +
          (ys.reduce((a, b) => a > b ? a : b) - ys.reduce((a, b) => a < b ? a : b));
      opacities[ms] = tester
          .widget<Opacity>(find.ancestor(
              of: find.descendant(
                  of: find.byType(TableView),
                  matching: find.byWidgetPredicate((w) => w is CardView && w.card == cards.first)),
              matching: find.byType(Opacity)).first)
          .opacity;
    }
    expect(opacities[100], 1.0, reason: 'solid while it is plainly on the felt');
    expect(spreads[10]!, greaterThan(50), reason: 'four cards apart at the start');
    expect(spreads[240]!, lessThan(1), reason: 'and one pile before it goes');
    expect(opacities[280]!, lessThan(0.2), reason: 'and gone by the end');

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
  });

  testWidgets('the hand closes over a played card without a jump', (tester) async {
    final hand = [for (final c in '2C.3C.4C.5C.6C'.split('.')) engine.Card.parse(c)];
    Widget fan(List<engine.Card> cards) => MaterialApp(
          home: Scaffold(
            body: SizedBox(height: TableLayout.portraitHandHeight, child: HandFan(hand: cards, onTap: (_) {})),
          ),
        );
    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fan(hand));
    final neighbour = hand.last;
    final was = tester.getTopLeft(cardFinder(neighbour)).dx;
    await tester.pumpWidget(fan(hand.sublist(0, 4)..removeAt(1) ..add(neighbour)));
    await tester.pump(const Duration(milliseconds: 16));
    final first = tester.getTopLeft(cardFinder(neighbour)).dx;
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(cardFinder(neighbour)).dx;
    final way = settled - was;
    expect(way.abs(), greaterThan(10), reason: 'the hand reflows');
    final share = (first - was) / way;
    expect(share, greaterThan(0), reason: 'under way on the first frame');
    expect(share, lessThan(0.15), reason: 'but eased off the mark, not a fifth of the way at once');
  });

  testWidgets('the finished trick goes to whoever took it', (tester) async {
    await pumpTable(tester, paced: true);
    await _passAnything(tester);
    final controller = tester.widget<TableView>(find.byType(TableView)).controller;

    // Play into the first trick and let it fill.
    for (var guard = 0; guard < 80 && controller.game.pendingTrick == null; guard++) {
      await tester.pump(const Duration(milliseconds: 100));
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (controller.awaitingPlay && playable.isNotEmpty) await tapCard(tester, playable.first.card);
    }
    final trick = controller.game.pendingTrick!;
    final slots = {for (final play in trick.plays) play.card: _feltCentre(tester, play.card)};

    // Swept: the four are off their slots, all of them going the one
    // way — towards the seat that took them.
    for (var guard = 0; guard < 100 && controller.game.pendingTrick != null; guard++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 150));
    final towards = seatDirection[controller.positionOf(trick.winner)]!;
    for (final play in trick.plays) {
      final moved = _feltCentre(tester, play.card) - slots[play.card]!;
      expect(moved.dx * towards.dx + moved.dy * towards.dy, greaterThan(20),
          reason: '${play.card} goes to the seat that took the trick');
    }
    expect(find.descendant(of: find.byType(TableView), matching: find.byType(CardGhost)), findsNWidgets(4),
        reason: 'and the slots they left are already empty');

    // Let the table run on to the player's turn, so the bots' clocks
    // are spent rather than left ticking into the next test.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
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
    expect(find.text('Hand 2  ·  Pass right  ·  to 50'), findsOneWidget);
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
    // At its own address, over the front door, as the app opens it, so
    // leaving has somewhere to go.
    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(routed(soloPath, extra: const SoloGame(seed: 4, paced: false)));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Leave the table'), findsOneWidget);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('dev'), findsWidgets, reason: 'the build tag, and its date');
    expect(find.text('Open source Hearts card game, no ads'), findsOneWidget, reason: 'the home page\'s tagline');
    for (final link in ['Code', 'License', 'Privacy', 'Terms']) {
      expect(find.widgetWithText(TextButton, link), findsOneWidget, reason: link);
    }
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave the table'));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsNothing);
    expect(find.text('home'), findsOneWidget, reason: 'back at the front door');
  });

  testWidgets('everyone\'s standing: on their badges, yours among them, no card counts', (tester) async {
    await pumpTable(tester);
    final model = tester.widget<TableView>(find.byType(TableView)).controller;
    // And where each sits, which a sighted player reads off the felt:
    // seat 1 plays after you and is drawn on your left.
    const where = ['', 'on your left', 'across from you', 'on your right'];
    for (var seat = 1; seat < engine.seatCount; seat++) {
      expect(find.bySemanticsLabel('${model.names[seat]}: 0 in the game, 0 this hand, ${where[model.positionOf(seat)]}'), findsOneWidget);
    }
    expect(find.bySemanticsLabel(RegExp(r'\d+ cards')), findsNothing);
    expect(find.bySemanticsLabel('You: 0 in the game, 0 this hand'), findsOneWidget);
    // In portrait your badge is the seat at the near edge of the felt:
    // on it, below the trick, and above your hand.
    final mine = tester.getRect(find.bySemanticsLabel('You: 0 in the game, 0 this hand'));
    final felt = tester.getRect(find.byType(TableView));
    final hand = tester.getRect(find.byType(HandFan));
    expect(mine.bottom, lessThanOrEqualTo(felt.bottom));
    expect(mine.top, greaterThan(_trickSlots(tester).map((r) => r.bottom).reduce((a, b) => a > b ? a : b)));
    expect(mine.bottom, lessThanOrEqualTo(hand.top));
  });

  testWidgets('a long name wraps or is cut, and every name is the same size as every other', (tester) async {
    // The test font draws every glyph an em wide, so names here are
    // twice their width on a phone: "Mumtaz Mahal" is too wide even
    // wrapped and is cut, while "Don Juan" wraps. Both in the east
    // seat, where the room is narrowest — found by searching the
    // seeds.
    int? seedFor(String name) {
      for (var s = 0; s < 500; s++) {
        final c = GameController(seed: s, paced: false, store: MemoryRecordStore());
        final found = c.names[3] == name;
        c.dispose();
        if (found) return s;
      }
      return null;
    }
    for (final name in ['Mumtaz Mahal', 'Don Juan']) {
      final seed = seedFor(name);
      expect(seed, isNotNull, reason: 'the roster seats $name east somewhere in 500 deals');
      await pumpTable(tester, seed: seed!, key: ValueKey(name));
      expect(tester.takeException(), isNull);
      final names = tester.widget<TableView>(find.byType(TableView)).controller.names;
      final east = tester.getRect(find.bySemanticsLabel(RegExp('^$name: ')));
      expect(east.right, lessThanOrEqualTo(_phone.width - 6));
      for (final slot in _trickSlots(tester)) {
        expect(east.overlaps(slot), isFalse, reason: '$name\'s badge stays clear of the trick');
      }
      expect(drawn(find.text(name)), findsOneWidget, reason: 'the name, on the badge');
      // One size for everyone: a name that does not fit is cut, not
      // shrunk, so nobody's name is smaller than anybody else's.
      final painted = <double>{
        for (final seat in [name, names[1], names[2]])
          tester.widget<Text>(drawn(find.text(seat))).style!.fontSize!
      };
      expect(painted, hasLength(1), reason: 'every badge sets the same size');
      for (final seat in [name, names[1], names[2]]) {
        final box = tester.renderObject<RenderBox>(drawn(find.text(seat)));
        final scale = _scaleOf(tester, drawn(find.text(seat)));
        expect(scale, closeTo(1.0, 0.001), reason: '$seat is drawn at the size it sets, not scaled to fit');
        expect(box.size.height, greaterThan(0));
      }
      if (name == 'Don Juan') {
        // Wrapped to two lines: taller than the north badge, which has
        // the whole width and stays on one.
        final north = tester.getRect(find.bySemanticsLabel(RegExp('^${names[2]}: ')));
        expect(east.height, greaterThan(north.height + 10));
        expect(tester.widget<Text>(drawn(find.text(name))).maxLines, 2);
      }
    }
  });

  testWidgets('on a felt too narrow for both, the trick gives way to the badges', (tester) async {
    await pumpTable(tester, size: const Size(340, 720));
    expect(tester.takeException(), isNull);
    final names = tester.widget<TableView>(find.byType(TableView)).controller.names;
    final slots = _trickSlots(tester);
    for (var seat = 1; seat < engine.seatCount; seat++) {
      final badge = tester.getRect(find.bySemanticsLabel(RegExp('^${names[seat]}: ')));
      for (final slot in slots) {
        expect(badge.overlaps(slot), isFalse, reason: '${names[seat]}\'s badge stays clear of the trick');
      }
    }
    // Shrunk from what the width alone would allow: 340 × 0.21 = 71.
    final slotWidth = slots.map((r) => r.width).reduce((a, b) => a > b ? a : b);
    expect(slotWidth, lessThan(60));
  });

  for (final shape in [_phone, _sideways, const Size(1280, 800), const Size(340, 720)]) {
    testWidgets('four seats, two matched pairs, each badge the same gap from the card it labels, at ${shape.width.toInt()}x${shape.height.toInt()}', (tester) async {
      await pumpTable(tester, size: shape);
      final names = tester.widget<TableView>(find.byType(TableView)).controller.names;
      final slots = _trickSlots(tester);
      Rect card(double Function(Rect) edge, bool most) =>
          slots.reduce((a, b) => (most ? edge(a) > edge(b) : edge(a) < edge(b)) ? a : b);
      Rect badge(String name) => tester.getRect(find.bySemanticsLabel(RegExp('^$name: ')));
      final seats = ['You', names[1], names[2], names[3]];

      // Each badge labels the card on its own side of the trick, and is
      // the same short gap from it as the other three are from theirs.
      final gaps = <String, double>{
        'north': card((r) => r.top, false).top - badge(names[2]).bottom,
        'south': badge('You').top - card((r) => r.bottom, true).bottom,
        'west': card((r) => r.left, false).left - badge(names[1]).right,
        'east': badge(names[3]).left - card((r) => r.right, true).right,
      };
      for (final e in gaps.entries) {
        expect(e.value, closeTo(gaps['north']!, 0.5), reason: '${e.key} sits as far off its card as the rest');
      }
      expect(gaps['north'], lessThan(16), reason: 'near enough to read as that card\'s label');

      // Two pairs, each pair one size: the seat across the felt and
      // your own at the near edge, and the two at the sides.
      for (final name in seats) {
        expect(find.bySemanticsLabel(RegExp('^$name: ')), findsOneWidget, reason: '$name has one badge');
      }
      void samePair(Rect a, Rect b, String which) {
        expect(a.width, closeTo(b.width, 0.5), reason: which);
        expect(a.height, closeTo(b.height, 0.5), reason: which);
      }

      samePair(badge('You'), badge(names[2]), 'you and the seat facing you');
      samePair(badge(names[1]), badge(names[3]), 'the two at the sides');

      // And nothing of the table runs off the felt.
      final felt = tester.getRect(find.byType(TableView));
      for (final name in seats) {
        expect(felt.contains(badge(name).topLeft), isTrue, reason: '$name is on the felt');
        expect(felt.contains(badge(name).bottomRight - const Offset(0.01, 0.01)), isTrue, reason: '$name is on the felt');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('your turn is told with a pill that glows and breathes, and holds still for reduced motion', (tester) async {
    turnPillBreathes = true;
    addTearDown(() => turnPillBreathes = false);
    await pumpTable(tester);
    final hand = fanCards(tester);
    for (var i = 0; i < 3; i++) {
      await tapCard(tester, hand[i].card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    // Not pumpAndSettle: a breathing pill never settles, which is the point.
    for (var i = 0; i < 60 && find.text('Your turn').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Your turn'), findsOneWidget);
    double glow() {
      final glowing = tester
          .widgetList<DecoratedBox>(find.ancestor(of: find.text('Your turn'), matching: find.byType(DecoratedBox)))
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.boxShadow?.isNotEmpty ?? false);
      return glowing.single.boxShadow!.single.color.a;
    }

    final seen = <double>[];
    for (var i = 0; i < 6; i++) {
      seen.add(glow());
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(seen.reduce((a, b) => a > b ? a : b) - seen.reduce((a, b) => a < b ? a : b), greaterThan(0.2),
        reason: 'the glow rises and falls: $seen');
    expect(seen.every((a) => a >= 0.25), isTrue, reason: 'and never goes out');
    // Gone from the table, the breathing stops with it.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the action line sits against the hand, and what the table says floats in the room under your badge', (tester) async {
    await pumpTable(tester);
    final hand = tester.getRect(find.byType(HandFan));
    expect(
      hand.top - tester.getRect(find.byType(ActionBar)).bottom,
      lessThanOrEqualTo(4),
      reason: 'the line about the hand — what you were passed, what to choose — sits against it',
    );

    // Once the pass is made it is your turn, and the table says so in
    // the middle of the room under your own badge rather than against
    // it.
    await _passAnything(tester);
    expect(find.text('Your turn'), findsOneWidget);
    final you = tester.getRect(find.bySemanticsLabel(RegExp('^You: ')));
    final room = Rect.fromLTRB(0, you.bottom, 1, tester.getRect(find.byType(ActionBar)).top);
    expect(tester.getRect(find.text('Your turn')).center.dy, closeTo(room.center.dy, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('every player has an icon: their initials on their colour, on the badges, your line and the sheet', (tester) async {
    await pumpTable(tester);
    final model = tester.widget<TableView>(find.byType(TableView)).controller;
    final icons = tester.widgetList<PlayerIcon>(drawn(find.byType(PlayerIcon))).toList();
    expect(icons.length, engine.seatCount, reason: 'three badges and your own line');
    for (var seat = 0; seat < engine.seatCount; seat++) {
      final mine = icons.where((i) => i.name == model.names[seat]).toList();
      expect(mine, hasLength(1), reason: '${model.names[seat]} has one icon');
      expect(mine.single.seed, model.iconSeedOf(seat));
    }
    // A bot's colour is its own, the same at every table; yours is yours.
    expect(icons.map((i) => PlayerIcon.colorOf(i.seed)).toSet().length, greaterThanOrEqualTo(2));
    // The sheet at the end of the hand shows them again.
    await _passAnything(tester);
    for (var guard = 0; guard < 60; guard++) {
      await tester.pumpAndSettle();
      if (find.text('Next hand').evaluate().isNotEmpty) break;
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isEmpty) continue;
      await tapCard(tester, playable.first.card);
    }
    expect(find.text('Next hand'), findsOneWidget);
    expect(drawn(find.byType(PlayerIcon)), findsNWidgets(engine.seatCount * 2), reason: 'the table\'s four, and the sheet\'s four');
  });

  testWidgets('sideways, the same header, a shorter and wider hand', (tester) async {
    await pumpTable(tester, size: _sideways);
    expect(tester.takeException(), isNull);
    expect(find.text('Hand 1  ·  Pass left  ·  to 50'), findsOneWidget);
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
    final strip = find.text('Hand 1  ·  Pass left  ·  to 50');
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
    expect(find.text('Hand 2  ·  Pass right  ·  to 50'), findsOneWidget);
  });
}

/// The four slots of the trick, empty or not, as rectangles on screen.
/// Where a card sits on the felt right now, wherever it is on its way
/// to or from.
Offset _feltCentre(WidgetTester tester, engine.Card card) => tester.getCenter(find.descendant(
    of: find.byType(TableView),
    matching: find.byWidgetPredicate((w) => w is CardView && w.card == card)));

List<Rect> _trickSlots(WidgetTester tester) {
  final felt = find.byType(TableView);
  final ghosts = find.descendant(of: felt, matching: find.byType(CardGhost));
  final cards = find.descendant(of: felt, matching: find.byType(CardView));
  return [
    for (final w in tester.widgetList(ghosts)) tester.getRect(find.byWidget(w)),
    for (final w in tester.widgetList(cards)) tester.getRect(find.byWidget(w)),
  ];
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
