/// The hand a new player is taught on (tutorial.dart), driven the way a
/// thumb drives it: each note as its moment comes, in the room the felt
/// gives it, the cards held while one is being read, and the score
/// sheet at the end saying Done and going home.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/coach_note.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'table_page_test.dart' show fanCards, tapCard;

/// A screen [size] big with the way in, and the taught hand pushed over
/// it.
Future<void> pumpLesson(WidgetTester tester, {Size size = const Size(390, 844)}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TablePage(learning: true, paced: false))),
            child: const Text('the door'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('the door'));
  await tester.pumpAndSettle();
}

/// Plays for the thumb: three cards to pass, or the first card it may.
Future<void> act(WidgetTester tester) async {
  if (find.text('Pass').evaluate().isNotEmpty) {
    final hand = fanCards(tester);
    for (var i = 0; i < 3; i++) {
      await tapCard(tester, hand[i].card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    await tester.pumpAndSettle();
    return;
  }
  final playable = fanCards(tester).where((c) => !c.dimmed).toList();
  if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a note at each first, the cards held while one is read, and Done going home', (tester) async {
    await pumpLesson(tester);
    final words = english;
    expect(find.text(words.tutorialWelcome), findsOneWidget);
    expect(find.descendant(of: find.byType(CoachNote), matching: find.text(words.tutorialNext)), findsOneWidget);

    // A card tapped while the note is up is not chosen: the note holds
    // the player's cards as it holds the bots'.
    await tapCard(tester, fanCards(tester).first.card);
    expect(find.text('Choose 3 more to pass'), findsOneWidget, reason: 'nothing chosen under the note');
    await tester.tap(find.text(words.tutorialNext));
    await tester.pumpAndSettle();
    expect(find.text(words.tutorialPass), findsOneWidget);
    expect(find.text(words.tutorialNext), findsNothing, reason: 'a note that asks has no Next: the pass is the answer');

    final notes = [
      words.tutorialWelcome, words.tutorialPass, words.tutorialReceived, words.tutorialYouLead, words.tutorialFollow,
      words.tutorialNoSuit('spades'), words.tutorialTrickTaken, words.tutorialHeartsBroken, words.tutorialQueen,
    ];
    final seen = <String>{words.tutorialWelcome};
    for (var guard = 0; guard < 300 && find.text(words.done).evaluate().isEmpty; guard++) {
      for (final note in notes) {
        if (find.text(note).evaluate().isNotEmpty) seen.add(note);
      }
      if (find.text(words.tutorialNext).evaluate().isNotEmpty) {
        // Nothing moves under a note being read, however long it is up,
        // and the trick a note is about is on the felt while it is.
        final game = tester.widget<TableView>(find.byType(TableView)).controller.game;
        if (find.text(words.tutorialTrickTaken).evaluate().isNotEmpty) {
          expect(game.pendingTrick, isNotNull, reason: 'the trick taken, still on the felt');
        }
        String table() => '${game.phase} ${game.tricksPlayed} ${game.trick.map((p) => p.card)} ${game.pendingTrick?.plays.map((p) => p.card)}';
        final before = table();
        await tester.pump(const Duration(minutes: 1));
        expect(table(), before, reason: 'the table moved under a note being read');
        await tester.tap(find.text(words.tutorialNext));
        await tester.pumpAndSettle();
        continue;
      }
      await act(tester);
      await tester.pumpAndSettle();
    }
    expect(seen, notes.toSet(), reason: 'every note came');
    // The sheet says how a hand is scored, and its one button goes home.
    expect(find.text(words.tutorialScore), findsOneWidget);
    expect(find.byType(CoachNote), findsNothing, reason: 'the score is the sheet\'s to say');
    expect(find.text(words.nextHand), findsNothing, reason: 'one hand, not a game');
    await tester.tap(find.text(words.done));
    await tester.pumpAndSettle();
    expect(find.text('the door'), findsOneWidget, reason: 'home again');
    expect((await SharedPreferences.getInstance()).getBool('tutorial_opened'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('upright the note is under the felt, on its side beside it, and the felt is laid out as without it', (tester) async {
    for (final size in [const Size(360, 640), const Size(844, 390), const Size(640, 360)]) {
      await pumpLesson(tester, size: size);
      expect(find.text(english.tutorialWelcome), findsOneWidget);
      final note = tester.getRect(find.byType(CoachNote));
      final felt = tester.getRect(find.byType(TableView));
      final action = tester.getRect(find.byType(ActionBar));
      if (size.width < size.height) {
        expect(note.top, greaterThanOrEqualTo(felt.bottom), reason: 'under the felt');
        expect(note.bottom, lessThanOrEqualTo(action.top), reason: 'and over the action line');
        // And no taller than it is: the felt has the rest.
        expect(note.top - felt.bottom, lessThan(3), reason: 'against the felt');
        expect(action.top - note.bottom, lessThan(5), reason: 'and against the action line');
        // The felt left is wider than tall by the felt's own measure of
        // wide; it is laid out upright all the same, as it is with no
        // note, its side badges stacked beside the trick.
        expect(felt.width, greaterThan(felt.height * 1.3), reason: 'a felt the note has made wide');
        final sides = tester.widgetList<SeatBadge>(find.byType(SeatBadge)).where((b) => b.position.isOdd);
        expect(sides.map((b) => b.oneLine), everyElement(isFalse), reason: 'laid out upright, as without the note');
      } else {
        expect(note.left, greaterThanOrEqualTo(felt.right), reason: 'beside the felt');
        expect(note.bottom, lessThanOrEqualTo(action.top), reason: 'and over the action line');
        // A narrow phone on its side keeps at least half its width for
        // the table.
        expect(felt.width, greaterThanOrEqualTo(note.width), reason: 'the felt keeps half the width');
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the felt keeps its place as notes come and go: nothing on it starts over', (tester) async {
    await pumpLesson(tester);
    final felt = tester.element(find.byType(TableView));
    var without = 0;
    for (var guard = 0; guard < 300 && find.text(english.done).evaluate().isEmpty; guard++) {
      if (find.byType(CoachNote).evaluate().isEmpty) without++;
      expect(tester.element(find.byType(TableView)), same(felt), reason: 'the same felt, note or none');
      if (find.text(english.tutorialNext).evaluate().isNotEmpty) {
        await tester.tap(find.text(english.tutorialNext));
      } else {
        await act(tester);
      }
      await tester.pumpAndSettle();
    }
    expect(without, greaterThan(0), reason: 'seen with no note up as well as with one');
  });

  testWidgets('a screen reader hears each note as it comes', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpLesson(tester);
    final node = tester.getSemantics(find.byType(CoachNote));
    expect(node.flagsCollection.isLiveRegion, isTrue, reason: 'said as it comes, without the reader looking for it');
    semantics.dispose();
  });
}
