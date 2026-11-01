/// The game options sheet (options_sheet.dart): what the player picks
/// is what they get, however they close it.
library;

import 'package:engine/engine.dart' show longGameScore;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/options_sheet.dart';

void main() {
  /// Opens the sheet over a page with the default options; what it
  /// resolves to lands in the list.
  Future<List<GameOptions?>> open(WidgetTester tester) async {
    final results = <GameOptions?>[];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
              onPressed: () async => results.add(await showGameOptions(context, current: const GameOptions())),
              child: const Text('options'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('options'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('Done keeps what was picked', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('Unrated'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(results, [const GameOptions(rated: false)]);
  });

  testWidgets('so does tapping outside the sheet', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('Unrated'));
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(results, [const GameOptions(rated: false)]);
  });

  testWidgets('and swiping it away', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('$longGameScore points'));
    await tester.pump();
    await tester.drag(find.text('Game options'), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(results, [const GameOptions(target: longGameScore)]);
  });

  testWidgets('closed with nothing changed, it says so', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('Unrated'));
    await tester.pump();
    await tester.tap(find.text('Rated'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });
}
