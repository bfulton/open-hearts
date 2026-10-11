/// A whole game, played by thumb, comes out as a record that replays to
/// the same result — and the record is on the device when it ends, and
/// Home leaves the table.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' as engine;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_hearts/record_store.dart';
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:open_hearts/theme.dart';

import 'table_page_test.dart' show fanCards, tapCard;

void main() {
  testWidgets('a finished game is kept, and its copy replays to the same scores', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The clipboard is a platform channel; catch what the app writes.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });

    // Opened from a front door, as the app opens it, so Home has
    // somewhere to go back to.
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const Scaffold(body: Text('the door'))));
    unawaited(tester.state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute<void>(builder: (_) => const TablePage(seed: 11, paced: false))));
    await tester.pumpAndSettle();

    // Play the game out: pass anything, play the first legal card, next hand.
    for (var guard = 0; guard < 2000; guard++) {
      await tester.pumpAndSettle();
      if (find.text('New game').evaluate().isNotEmpty) break;
      if (find.text('Next hand').evaluate().isNotEmpty) {
        await tester.tap(find.text('Next hand'));
        continue;
      }
      if (find.widgetWithText(FilledButton, 'Pass').evaluate().isNotEmpty) {
        final hand = fanCards(tester);
        for (var i = 0; i < 3; i++) {
          await tapCard(tester, hand[i].card);
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
        continue;
      }
      final playable = fanCards(tester).where((c) => !c.dimmed).toList();
      if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
    }
    expect(find.text('New game'), findsOneWidget, reason: 'the game ran to its end');

    final controller = tester.widget<TableView>(find.byType(TableView)).controller as GameController;
    final game = controller.game;
    expect(game.phase, engine.Phase.gameOver);

    await tester.tap(find.text('Copy record'));
    await tester.pumpAndSettle();
    expect(find.text('Record copied'), findsOneWidget);
    expect(copied, controller.recordText);

    final record = engine.SoloRecord.parse(copied!);
    expect(record, isNotNull);
    expect(record!.seed, 11);
    final replay = record.replay();
    expect(replay.complete, isTrue, reason: 'the record covers the whole game');
    expect(replay.game.totals, game.totals);
    expect(replay.hands.length, game.handNumber + 1);

    // And it is on the device, newest first.
    final kept = await PrefsRecordStore().load();
    expect(kept, [copied]);

    // Done for now: Home, beside the record, leaves the table.
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.byType(TablePage), findsNothing);
    expect(find.text('the door'), findsOneWidget);
  });
}
