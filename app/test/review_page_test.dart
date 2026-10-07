/// A finished game, as the review shows it: checked first, then every
/// hand — and a record that does not check out, or none, says so.
library;

import 'dart:async';
import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/crypto/deal.dart';
import 'package:open_hearts/net/record_check.dart';
import 'package:open_hearts/net/watching.dart';
import 'package:engine/engine.dart' show Card, Phase, twoOfClubs;
import 'package:open_hearts/review_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

void main() {
  late GameRecord played;
  // The hands as the real check gives them, to hand over one at a time.
  final checked = <RecordCheck>[];
  setUpAll(() async {
    dealCrypto = await DealCrypto.load();
    final t = SimTable(humans: 4, seed: 3, crypto: dealCrypto);
    t.start();
    expect(t.run(), isTrue);
    played = GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'});
    t.stop();
    await checkRecord(played).forEach(checked.add);
  });

  Future<void> pumpReview(WidgetTester tester, GameRecord? record) async {
    tester.view
      ..physicalSize = const Size(390, 1600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReviewPage(table: played.spec.id, load: (_) async => record)));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('a kept game is checked, then shown hand by hand: the deal, the passes, every trick', (tester) async {
    await pumpReview(tester, played);
    for (final name in ['Ada', 'Bao', 'Cy', 'Dee']) {
      expect(find.text(name), findsWidgets, reason: name);
    }
    expect(find.text('Hand 1  ·  Pass left'), findsOneWidget);
    expect(find.text('Trick 13'), findsOneWidget, reason: 'every trick of the hand');
    await tester.tap(find.widgetWithText(ChoiceChip, '4'));
    await tester.pumpAndSettle();
    expect(find.text('Hand 4  ·  No pass'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen reader reads it piece by piece, every card by its name and who played it', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpReview(tester, played);
    expect(find.bySemanticsLabel('Hand 1  ·  Pass left'), findsOneWidget);
    // Each trick by its number, each card by its name and who played it.
    expect(find.bySemanticsLabel('Trick 1'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^\w+ of \w+, (Ada|Bao|Cy|Dee)$')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('a record changed after the game does not check out, and nothing of it is shown', (tester) async {
    final json = jsonDecode(jsonEncode(played.toJson())) as Map<String, Object?>;
    // Two decisions swapped: every signature still checks, the game does not.
    final record = json['record'] as List;
    final a = record[30];
    record[30] = record[31];
    record[31] = a;
    await pumpReview(tester, GameRecord.parse(json));
    expect(find.textContaining('does not check out'), findsOneWidget);
    expect(find.text('Trick 1'), findsNothing);
  });

  testWidgets('no game kept at the address: said so', (tester) async {
    await pumpReview(tester, null);
    expect(find.text('No finished game is kept at this address.'), findsOneWidget);
  });

  testWidgets('hands are shown as their check is done, the rest said to be still checking; a failure later takes them away', (tester) async {
    final hands = checked.whereType<HandChecked>().toList();
    final verdict = checked.last as RecordChecked;
    expect(verdict.ok, isTrue);

    Future<StreamController<RecordCheck>> open() async {
      final checking = StreamController<RecordCheck>();
      tester.view
        ..physicalSize = const Size(390, 1600)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: ReviewPage(key: UniqueKey(), table: played.spec.id, load: (_) async => played, check: (_) => checking.stream),
      ));
      await tester.pump();
      await tester.pump();
      return checking;
    }

    var checking = await open();
    expect(find.text('Checking every card of the game.'), findsOneWidget, reason: 'nothing checked yet');
    checking.add(hands.first);
    await tester.pump();
    expect(find.text('Hand 1  ·  Pass left'), findsOneWidget, reason: 'the first hand, as soon as it is checked');
    expect(find.text('Checking the rest of the game…'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '2'), findsNothing, reason: 'no hand not yet checked');
    for (final h in hands.skip(1)) {
      checking.add(h);
    }
    checking.add(verdict);
    await tester.pumpAndSettle();
    expect(find.text('Checking the rest of the game…'), findsNothing, reason: 'all checked');
    expect(find.widgetWithText(ChoiceChip, '4'), findsOneWidget);
    await checking.close();

    // A record that fails after its first hands were shown: none of it stays.
    checking = await open();
    checking.add(hands.first);
    await tester.pump();
    expect(find.text('Trick 1'), findsOneWidget);
    checking.add(const RecordChecked(ok: false, reason: 'a play out of turn'));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not check out'), findsOneWidget);
    expect(find.text('Trick 1'), findsNothing);
    await checking.close();
  });

  testWidgets('a game still being played is watched: the scores and each card as it comes, no hand; over, the checked game takes its place', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 1600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    GameRecord? kept;
    final views = StreamController<Watched>();
    final hands = checked.whereType<HandChecked>().toList();
    final verdict = checked.last as RecordChecked;
    final checking = StreamController<RecordCheck>();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: ReviewPage(
        table: played.spec.id,
        load: (_) async => kept,
        watch: (_) => views.stream,
        check: (_) => checking.stream,
      ),
    ));
    await tester.pump();
    WatchedTable view(int seq, Phase phase, List<({int seat, Card card})> plays, {int? toPlay, List<int> totals = const [0, 0, 0, 0]}) => WatchedTable(
          table: played.spec.id,
          target: 50,
          seq: seq,
          hand: 0,
          phase: phase,
          names: const ['Ada', 'Bao', 'Cy', 'Dee'],
          totals: totals,
          taken: const [0, 0, 0, 0],
          plays: plays,
          toPlay: toPlay,
        );
    views.add(Viewed(view(10, Phase.playing, [(seat: 2, card: twoOfClubs)], toPlay: 3)));
    await tester.pump();
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Hand 1  ·  Pass left'), findsOneWidget);
    expect(find.text('Dee to play'), findsOneWidget);
    expect(find.text('Trick 1'), findsOneWidget);
    expect(find.bySemanticsLabel('2 of clubs, Cy'), findsOneWidget);

    // A card later: the same trick, one more card.
    views.add(Viewed(view(11, Phase.playing, [(seat: 2, card: twoOfClubs), (seat: 3, card: Card.parse('KC'))], toPlay: 0)));
    await tester.pump();
    expect(find.text('Ada to play'), findsOneWidget);
    expect(find.bySemanticsLabel('king of clubs, Dee'), findsOneWidget);

    // Over: the record is asked for until it is kept, then checked and shown.
    views.add(Viewed(view(400, Phase.gameOver, const [], totals: const [12, 55, 30, 8])));
    await tester.pump();
    await tester.pump(ReviewPage.recordAgain);
    kept = played;
    await tester.pump(ReviewPage.recordAgain);
    await tester.pump();
    for (final h in hands) {
      checking.add(h);
    }
    checking.add(verdict);
    await tester.pumpAndSettle();
    expect(find.text('Live'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '4'), findsOneWidget, reason: 'the whole game, checked');
    // Let go by the page once the game was over: closed, not waited on.
    unawaited(views.close());
    await checking.close();
  });
}
