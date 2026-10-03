/// A finished game, as the review shows it: checked first, then every
/// hand — and a record that does not check out, or none, says so.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/crypto/deal.dart';
import 'package:open_hearts/review_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

void main() {
  late GameRecord played;
  setUpAll(() async {
    dealCrypto = await DealCrypto.load();
    final t = SimTable(humans: 4, seed: 3, crypto: dealCrypto);
    t.start();
    expect(t.run(), isTrue);
    played = GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'});
    t.stop();
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
}
