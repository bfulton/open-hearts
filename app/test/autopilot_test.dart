/// The Auto switch: offered beside the hand once nothing the player
/// holds can change how it comes out (engine, autopilot.dart), and on,
/// the rest of the hand played for them — rightmost legal card first,
/// at once, solo and live alike.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/table_model.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/table_view.dart';

import 'live_page_test.dart' show pumpLive, act;

/// A deal whose first hand, played by the first legal card, comes to
/// the switch with five cards still to play.
const _seed = 156;

/// The table, solo, in [locale] and at [textScale], [size] big.
Future<TableModel> _pumpTable(WidgetTester tester,
    {Size size = const Size(390, 844), Locale locale = const Locale('en'), double textScale = 1, bool paced = false}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: TablePage(seed: _seed, paced: paced),
  ));
  if (paced) {
    await tester.pump(const Duration(seconds: 2));
  } else {
    await tester.pumpAndSettle();
  }
  return tester.widget<TableView>(find.byType(TableView)).controller;
}

/// The first three cards passed, and the first legal card played,
/// until the switch is offered on the player's turn. What comes back
/// is how tall the action line was on the player's last turn before.
Future<double> _playToOffer(WidgetTester tester, TableModel c, {bool paced = false}) async {
  Future<void> settle() => paced ? tester.pump(const Duration(milliseconds: 100)) : tester.pumpAndSettle();
  var line = 0.0;
  for (var guard = 0; guard < 2000; guard++) {
    if (c.autoOffered && c.awaitingPlay) return line;
    if (c.awaitingPass) {
      for (final card in c.handShown.take(engine.passSize)) {
        c.toggleSelected(card);
      }
      c.confirmPass();
    } else if (c.awaitingPlay) {
      expect(find.byType(AutoSwitch), findsNothing, reason: 'not offered yet');
      line = tester.getSize(find.byType(ActionBar)).height;
      c.playCard(c.handShown.firstWhere(c.legalNow.contains));
    }
    await settle();
  }
  fail('the switch never came');
}

/// Each card the player played, by the trick it went to, and the card
/// the switch should have played there — the rightmost legal one —
/// wherever it was the player's turn with the switch on.
({Map<int, engine.Card> played, Map<int, engine.Card> rightmost}) _watchPlays(TableModel c) {
  final played = <int, engine.Card>{};
  final rightmost = <int, engine.Card>{};
  var before = c.handShown;
  void look() {
    final hand = c.game.knowsHand(c.mySeat) ? c.handShown : <engine.Card>[];
    final trick = c.game.tricksPlayed;
    for (final gone in before.where((x) => !hand.contains(x))) {
      played[trick] = gone;
    }
    if (c.autoPlay && c.awaitingPlay) rightmost[trick] = engine.autoPlayCard(hand, c.legalNow);
    before = hand;
  }

  c.addListener(look);
  return (played: played, rightmost: rightmost);
}

/// Everything said aloud while [body] runs.
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
  testWidgets('not through the pass, nor the start of the play', (tester) async {
    final c = await _pumpTable(tester);
    expect(c.awaitingPass, isTrue);
    expect(find.byType(AutoSwitch), findsNothing);
    for (final card in c.handShown.take(engine.passSize)) {
      c.toggleSelected(card);
    }
    c.confirmPass();
    await tester.pumpAndSettle();
    expect(c.game.phase, engine.Phase.playing);
    expect(find.byType(AutoSwitch), findsNothing);
    expect(c.autoOffered, isFalse);
  });

  testWidgets('offered beside the hand, said aloud and labelled; on, the rest of the hand plays itself, rightmost first',
      (tester) async {
    late TableModel c;
    final said = await _heard(tester, () async {
      c = await _pumpTable(tester);
      await _playToOffer(tester, c);
    });
    expect(said, contains(english.autoOffered), reason: 'the switch is said as it appears');
    expect(c.handShown.length, greaterThanOrEqualTo(2));
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Auto-play the rest of this hand'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse, reason: 'off until the player turns it on');
    expect(
      tester.getSemantics(find.bySemanticsLabel('Auto-play the rest of this hand')),
      isSemantics(label: 'Auto-play the rest of this hand', hasToggledState: true, isToggled: false, hasTapAction: true),
    );
    handle.dispose();

    // Just above the right end of the hand: the card it plays.
    final toggle = tester.getRect(find.byType(AutoSwitch));
    final hand = tester.getRect(find.byType(HandFan));
    expect(hand.top - toggle.bottom, inInclusiveRange(0, 16));

    final watched = _watchPlays(c);
    final left = c.handShown.length;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    // Every card, the last one included, without a tap.
    expect(find.text('Next hand'), findsOneWidget);
    expect(watched.rightmost.length, left);
    expect(watched.played.entries.where((e) => watched.rightmost.containsKey(e.key)).length, left);
    for (final MapEntry(key: trick, value: card) in watched.rightmost.entries) {
      expect(watched.played[trick], card, reason: 'trick ${trick + 1}: the rightmost legal card');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('off, and gone, at the start of every hand', (tester) async {
    final c = await _pumpTable(tester);
    await _playToOffer(tester, c);
    c.setAutoPlay(true);
    await tester.pumpAndSettle();
    expect(find.text('Next hand'), findsOneWidget);
    await tester.tap(find.text('Next hand'));
    await tester.pumpAndSettle();
    expect(c.autoPlay, isFalse);
    expect(c.autoOffered, isFalse);
    expect(find.byType(AutoSwitch), findsNothing);

    // The second hand is played by hand to its end: nothing plays itself,
    // and wherever the switch is up it is off — and it is never up with
    // one card left.
    for (var guard = 0; guard < 400 && find.text('Next hand').evaluate().isEmpty; guard++) {
      if (c.awaitingPass) {
        for (final card in c.handShown.take(engine.passSize)) {
          c.toggleSelected(card);
        }
        c.confirmPass();
      } else if (c.awaitingPlay) {
        if (c.handShown.length < 2) expect(find.byType(AutoSwitch), findsNothing);
        if (find.byType(AutoSwitch).evaluate().isNotEmpty) {
          expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
        }
        c.playCard(c.handShown.firstWhere(c.legalNow.contains));
      }
      await tester.pumpAndSettle();
      if (c.game.phase == engine.Phase.playing && c.game.currentSeat == c.mySeat && c.game.pendingTrick == null) {
        expect(c.awaitingPlay, isTrue, reason: 'the player\'s turn waits for the player');
      }
    }
    expect(find.text('Next hand'), findsOneWidget);
  });

  testWidgets('turned off mid-hand, the player plays by hand again', (tester) async {
    final c = await _pumpTable(tester);
    await _playToOffer(tester, c);
    final left = c.handShown.length;
    c.setAutoPlay(true); // plays this turn, then
    c.setAutoPlay(false); // off before the next comes round
    await tester.pumpAndSettle();
    expect(c.handShown.length, left - 1);
    expect(c.awaitingPlay, isTrue, reason: 'the next turn is the player\'s to take');
    expect(find.byType(AutoSwitch), findsOneWidget, reason: 'and the switch is still there to turn back on');
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('on, the player\'s turn is played at once, without a beat', (tester) async {
    final c = await _pumpTable(tester, paced: true);
    await _playToOffer(tester, c, paced: true);
    final left = c.handShown.length;
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(c.handShown.length, left - 1, reason: 'played the frame it was turned on');
    // And each turn after it as it comes round, with the table's pace
    // for everyone else.
    for (var t = 0; t < 400 && c.game.phase == engine.Phase.playing; t++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.game.phase, engine.Phase.handOver);
    await tester.pump(const Duration(seconds: 3));
  });

  // Beside the hand, never over anything: the hand, the line it shares,
  // the badges, what the table says — at a phone in either hand, a
  // tablet, a desktop, and the longest language at twice the type.
  for (final (size, locale, scale) in [
    (const Size(390, 844), 'en', 1.0),
    (const Size(390, 844), 'de', 1.0),
    (const Size(390, 844), 'de', 2.0),
    (const Size(360, 640), 'fr', 1.5),
    (const Size(320, 568), 'de', 2.0),
    (const Size(844, 390), 'en', 1.0),
    (const Size(844, 390), 'de', 2.0),
    (const Size(768, 1024), 'pt', 1.0),
    (const Size(1280, 800), 'de', 1.0),
    (const Size(1920, 1080), 'es', 2.0),
  ]) {
    testWidgets('clear of everything at ${size.width.toInt()}x${size.height.toInt()}, $locale, text ×$scale', (tester) async {
      // At large type the table has overflows of its own — a card's
      // rank, the felt on a small phone — which are not this switch's
      // to answer for; anything of the switch's, or its line's, is.
      final overflows = <String>[];
      final reported = FlutterError.onError;
      FlutterError.onError = (d) => overflows.add(d.toString());
      addTearDown(() => FlutterError.onError = reported);
      final c = await _pumpTable(tester, size: size, locale: Locale(locale), textScale: scale);
      final before = await _playToOffer(tester, c);
      if (scale == 1) expect(overflows, isEmpty, reason: 'nothing overflows');
      expect(overflows.where((o) => o.contains('AutoSwitch') || o.contains('ActionBar')), isEmpty);
      // The switch takes a place on the line the hand already had,
      // so nothing above it moves when it comes.
      expect(tester.getSize(find.byType(ActionBar)).height, before);
      final toggle = tester.getRect(find.byType(AutoSwitch));
      final screen = Offset.zero & size;
      expect(screen.intersect(toggle), toggle, reason: 'on the screen, whole');

      void clear(Iterable<Element> what, String name) {
        for (final e in what) {
          final box = e.renderObject;
          if (box is! RenderBox || !box.hasSize || box.size.isEmpty) continue;
          final r = box.localToGlobal(Offset.zero) & box.size;
          expect(r.overlaps(toggle), isFalse, reason: '$name at $r under the switch at $toggle');
        }
      }

      clear(find.descendant(of: find.byType(HandFan), matching: find.byType(CardView)).evaluate(), 'a card');
      clear(find.byType(HandFan).evaluate(), 'the hand');
      clear(find.byType(SeatBadge).evaluate(), 'a badge');
      clear(find.descendant(of: find.byType(TableView), matching: find.byType(Text)).evaluate(), 'the felt\'s words');
      // What else the action line says: it gives the switch its room.
      final switchOwn = find.descendant(of: find.byType(AutoSwitch), matching: find.byType(Text)).evaluate().toSet();
      clear(
          find
              .descendant(of: find.byType(ActionBar), matching: find.byWidgetPredicate((w) => w is Text || w is Icon))
              .evaluate()
              .where((e) => !switchOwn.contains(e)),
          'the action line');
      // And a touch on it is the switch's, not the hand's under it.
      final hit = tester.hitTestOnBinding(tester.getCenter(find.byType(Switch)));
      final targets = [for (final e in hit.path) e.target];
      expect(targets, contains(tester.renderObject(find.byType(Switch))));
      expect(targets, isNot(contains(tester.renderObject(find.byType(HandFan)))));
    });
  }

  testWidgets('at a live table: offered, and on, the player\'s own plays sent at once, each once', (tester) async {
    final live = await pumpLive(tester);
    final c = live.controller;
    // Played by the first legal card until the switch comes with more
    // than a card to save.
    for (var guard = 0; guard < 4000 && !(c.autoOffered && c.awaitingPlay && c.handShown.length >= 3); guard++) {
      // A hand's sheet, out of the way of the next.
      if (find.text('On with it').evaluate().isNotEmpty) {
        await tester.tap(find.text('On with it'));
        await tester.pumpAndSettle();
      }
      await act(tester, live);
      await live.advance(tester, 300);
    }
    expect(c.autoOffered && c.awaitingPlay, isTrue, reason: 'the switch came');
    final hand = c.game.handNumber;
    expect(find.byType(AutoSwitch), findsOneWidget);

    final watched = _watchPlays(c);
    final left = c.handShown.length;
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(c.pendingPlay, isNotNull, reason: 'the turn is played at once, as a tap plays it');
    for (var guard = 0; guard < 400 && c.game.handNumber == hand; guard++) {
      await live.advance(tester, 300);
    }
    expect(c.game.handNumber, hand + 1, reason: 'the hand played itself out');
    expect(watched.rightmost.length, left);
    for (final MapEntry(key: trick, value: card) in watched.rightmost.entries) {
      expect(watched.played[trick], card, reason: 'trick ${trick + 1}: the rightmost legal card');
    }
    // Each of the player's cards once in the table's record, no more.
    final mine = [
      for (final d in c.client.record)
        if (d.turn.hand == hand && d.event.seat == c.mySeat && d.event.body['card'] != null) d.event.body['card'],
    ];
    expect(mine, hasLength(13));
    expect(mine.toSet(), hasLength(13));
    expect(c.autoPlay, isFalse, reason: 'off for the next hand');
    expect(tester.takeException(), isNull);
  });
}
