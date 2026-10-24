/// What a screen reader has, and what it is told as it happens — found
/// by playing a hand with nothing but the accessibility tree, the way a
/// blind player plays it (docs/explanation/screens.md).
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every announcement made while [body] runs, as it was said.
Future<List<String>> _heard(WidgetTester tester, Future<void> Function() body) async {
  final said = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (message) async {
    final m = message as Map;
    if (m['type'] == 'announce') said.add((m['data'] as Map)['message'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));
  await body();
  return said;
}

void main() {
  testWidgets('who took the trick, and that it is your turn, are said as they happen', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final said = await _heard(tester, () async {
      // At the app's own pace: a trick taken is held on the felt for a
      // moment, which is the moment it is said.
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const TablePage(seed: 4)));
      await tester.pump(const Duration(seconds: 2));
      final c = tester.widget<TableView>(find.byType(TableView)).controller;
      for (final card in c.game.handOf(c.mySeat).take(engine.passSize)) {
        c.toggleSelected(card);
      }
      c.confirmPass();
      // Three tricks' worth, played by the first legal card.
      for (var i = 0; i < 3; i++) {
        for (var t = 0; t < 200 && !c.awaitingPlay; t++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        c.playCard(c.legalNow.first);
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (var t = 0; t < 60; t++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
    expect(said.where((s) => s == 'Your turn').length, greaterThanOrEqualTo(3), reason: 'each of three turns: $said');
    expect(said.where((s) => RegExp(r'^(.+ takes it|You take it)(, \d+ points?)?$').hasMatch(s)).length, greaterThanOrEqualTo(3),
        reason: 'each trick taken: $said');
  });

  testWidgets('a score line is said as what its numbers are', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const TablePage(seed: 4, paced: false)));
    await tester.pumpAndSettle();
    final c = tester.widget<TableView>(find.byType(TableView)).controller;
    while (c.game.phase != engine.Phase.handOver) {
      if (c.awaitingPass) {
        for (final card in c.game.handOf(c.mySeat).take(engine.passSize)) {
          c.toggleSelected(card);
        }
        c.confirmPass();
      } else if (c.awaitingPlay) {
        c.playCard(c.legalNow.first);
      }
      await tester.pumpAndSettle();
    }
    for (var seat = 0; seat < engine.seatCount; seat++) {
      // Alone, every seat but yours a bot, and said to be one.
      final who = seat == c.mySeat ? c.names[seat] : '${c.names[seat]}, a bot';
      final label = '$who: ${c.game.handScores[seat]} this hand, ${c.game.totals[seat]} in the game';
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('the front door has no button without a name', (tester) async {
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Entitlement.current = Entitlement();
    addTearDown(() => Entitlement.current = Entitlement());
    await Entitlement.current.load((await Identity.signer()).publicKey);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: const MediaQuery(data: MediaQueryData(disableAnimations: true), child: HomePage(online: false)),
    ));
    await tester.pumpAndSettle();
    final nameless = <String>[];
    void walk(SemanticsNode node) {
      // Anything that can be tapped is a button to a browser's screen
      // reader (the web engine gives it the role), named or not.
      final data = node.getSemanticsData();
      final tappable = data.flagsCollection.isButton || data.hasAction(SemanticsAction.tap);
      if (tappable && !node.isMergedIntoParent && data.label.trim().isEmpty && data.value.isEmpty) nameless.add(node.toString());
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
    expect(nameless, isEmpty);
    handle.dispose();
  });
}
