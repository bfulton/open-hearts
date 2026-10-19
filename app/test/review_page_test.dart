/// A finished game, as the review shows it: checked first, then every
/// hand — and a record that does not check out, or none, says so.
library;

import 'dart:async';
import 'dart:convert';

import 'package:engine/engine.dart' show Card, Phase, twoOfClubs;
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/crypto/deal.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/net/in_use.dart';
import 'package:open_hearts/net/record_check.dart';
import 'package:open_hearts/net/remote_config.dart' show waits;
import 'package:open_hearts/net/watching.dart';
import 'package:open_hearts/pictures.dart';
import 'package:open_hearts/review_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

/// Long enough for the next of a hand's rows to be drawn (review_page.dart,
/// _HandRows).
const rowsLater = Duration(milliseconds: 20);

void main() {
  late GameRecord played;
  late KeptGame kept;
  // The hands as the real check gives them, to hand over one at a time.
  final checked = <RecordCheck>[];
  setUpAll(() async {
    dealCrypto = await rememberedCrypto();
    final t = SimTable(humans: 4, seed: 3, crypto: dealCrypto);
    t.start();
    expect(t.run(), isTrue);
    played = GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'});
    t.stop();
    kept = KeptGame.of(played);
    await checkRecord(kept).forEach(checked.add);
  });

  Future<void> pumpReview(WidgetTester tester, KeptGame? record, {Pictures? pictures}) async {
    tester.view
      ..physicalSize = const Size(390, 1600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: ReviewPage(table: played.spec.id, load: (_) async => record, pictures: pictures ?? Pictures())));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('a kept game is checked, then shown hand by hand: the deal, the passes, every trick', (tester) async {
    await pumpReview(tester, kept);
    for (final name in ['Ada', 'Bao', 'Cy', 'Dee']) {
      expect(find.text(name), findsWidgets, reason: name);
    }
    expect(find.text('Hand 1  ·  Pass left'), findsOneWidget);
    expect(find.text('Trick 13'), findsOneWidget, reason: 'every trick of the hand');
    await tester.tap(find.bySemanticsLabel('Hand 4'));
    await tester.pumpAndSettle();
    expect(find.text('Hand 4  ·  No pass'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a player this device blocked is shown by no name, in every hand', (tester) async {
    final bao = (played.spec.seats[1] as HumanSeat).account;
    await pumpReview(tester, kept, pictures: Pictures(blocked: {bao}));
    expect(find.textContaining('Bao'), findsNothing);
    expect(find.text('Blocked player'), findsWidgets);
    for (final name in ['Ada', 'Cy', 'Dee']) {
      expect(find.text(name), findsWidgets, reason: name);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen reader reads it piece by piece, every card by its name and who played it', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpReview(tester, kept);
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
    await pumpReview(tester, KeptGame.read(jsonEncode(json)));
    expect(find.textContaining('does not check out'), findsOneWidget);
    expect(find.text('Trick 1'), findsNothing);
  });

  testWidgets('a record with a signature that does not check does not check out: the page reads none of them, the check every one', (tester) async {
    final json = jsonDecode(jsonEncode(played.toJson())) as Map<String, Object?>;
    final event = ((json['record'] as List)[30] as Map)['event'] as Map;
    final sig = event['sig'] as String;
    event['sig'] = '${sig.substring(0, sig.length - 1)}${sig.endsWith('0') ? '1' : '0'}';
    final forged = KeptGame.read(jsonEncode(json));
    expect(forged, isNotNull, reason: 'the page reads the table and the names, and nothing it would have to check');
    await pumpReview(tester, forged);
    expect(find.textContaining('does not check out'), findsOneWidget);
    expect(find.textContaining(unsignedRecord), findsOneWidget);
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
        home: ReviewPage(key: UniqueKey(), table: played.spec.id, load: (_) async => kept, check: (_) => checking.stream),
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
    expect(find.bySemanticsLabel('Hand 2'), findsNothing, reason: 'no hand not yet checked');
    // The hand's hundred cards a few rows a frame, from the top, so the
    // page answers between them: the page around them first, then a
    // seat's thirteen, then the rest.
    expect(find.bySemanticsLabel(RegExp(r'^\w+ of \w+$')), findsNothing, reason: 'the page around the hand first');
    await tester.pump(rowsLater);
    expect(find.bySemanticsLabel(RegExp(r'^\w+ of \w+$')), findsNWidgets(13), reason: 'then one seat\'s hand');
    expect(find.text('Trick 1'), findsNothing);
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(rowsLater);
    }
    expect(find.bySemanticsLabel(RegExp(r'^\w+ of \w+$')), findsNWidgets(52), reason: 'every seat\'s, a few frames on');
    expect(find.text('Trick 13'), findsOneWidget, reason: 'and every trick');
    for (final h in hands.skip(1)) {
      checking.add(h);
    }
    checking.add(verdict);
    await tester.pumpAndSettle();
    expect(find.text('Checking the rest of the game…'), findsNothing, reason: 'all checked');
    expect(find.bySemanticsLabel('Hand 4'), findsOneWidget);
    await checking.close();

    // A record that fails after its first hands were shown: none of it stays.
    checking = await open();
    checking.add(hands.first);
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(rowsLater);
    }
    expect(find.text('Trick 1'), findsOneWidget);
    checking.add(const RecordChecked(ok: false, reason: 'a play out of turn'));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not check out'), findsOneWidget);
    expect(find.text('Trick 1'), findsNothing);
    await checking.close();
  });

  testWidgets('a check that stops with an error: the game could not be checked here, and none of it stays', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 1600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final checking = StreamController<RecordCheck>();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: ReviewPage(table: played.spec.id, load: (_) async => kept, check: (_) => checking.stream),
    ));
    await tester.pump();
    await tester.pump();
    checking.add(checked.whereType<HandChecked>().first);
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(rowsLater);
    }
    expect(find.text('Trick 1'), findsOneWidget);
    checking.addError(StateError('the check fell over'));
    await tester.pumpAndSettle();
    expect(find.text('This device cannot check the deal, so it cannot show the game.'), findsOneWidget);
    expect(find.text('Trick 1'), findsNothing);
    expect(find.text('Checking the rest of the game…'), findsNothing, reason: 'not left checking');
    await checking.close();
  });

  testWidgets('a game still being played is watched: the scores and each card as it comes, no hand; over, the checked game takes its place', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 1600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    KeptGame? keptNow;
    final views = StreamController<Watched>();
    final hands = checked.whereType<HandChecked>().toList();
    final verdict = checked.last as RecordChecked;
    final checking = StreamController<RecordCheck>();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: ReviewPage(
        table: played.spec.id,
        load: (_) async => keptNow,
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
    await tester.pump(waits.recordAgain);
    keptNow = kept;
    await tester.pump(waits.recordAgain);
    await tester.pump();
    for (final h in hands) {
      checking.add(h);
    }
    checking.add(verdict);
    await tester.pumpAndSettle();
    expect(find.text('Live'), findsNothing);
    expect(find.bySemanticsLabel('Hand 4'), findsOneWidget, reason: 'the whole game, checked');
    // Let go by the page once the game was over: closed, not waited on.
    unawaited(views.close());
    await checking.close();
  });

  testWidgets('watching stops when the account is suspended, and the page says where live play would be sold', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() {
      Entitlement.current = Entitlement();
      InUse.current = InUse();
    });
    tester.view
      ..physicalSize = const Size(390, 1600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var cancelled = false;
    final views = StreamController<Watched>(onCancel: () => cancelled = true);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: ReviewPage(table: played.spec.id, load: (_) async => null, watch: (_) => views.stream),
    ));
    await tester.pump();
    views.add(Viewed(WatchedTable(
      table: played.spec.id,
      target: 50,
      seq: 10,
      hand: 0,
      phase: Phase.playing,
      names: const ['Ada', 'Bao', 'Cy', 'Dee'],
      totals: const [0, 0, 0, 0],
      taken: const [0, 0, 0, 0],
      plays: const [],
      toPlay: 0,
    )));
    await tester.pump();
    expect(find.text('Live'), findsOneWidget);

    InUse.current.turnedAway('suspended: this account is suspended from live play');
    await tester.pump();
    expect(cancelled, isTrue, reason: 'no longer watched');
    expect(find.text('Live'), findsNothing);
    expect(find.text('Watching a game, and looking at one played, is part of live play.'), findsOneWidget);
    expect(find.text('Subscribe'), findsOneWidget, reason: 'which says the account is suspended');
    expect(find.text('Your account is in use on another device.'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    unawaited(views.close());
  });
}
