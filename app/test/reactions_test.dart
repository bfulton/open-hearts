/// Quick reactions at a live table (packages/table, reactions.dart;
/// ui/reactions.dart): the button beside the player's own badge and
/// the six it offers; a reaction beside its sender's badge for three
/// seconds, on every screen at the table and watching it, said aloud
/// politely; the switch that hides the others'; and nobody else's to
/// send — not a watcher's, not a bot's, not a table alone.
///
/// The player sits at seat 2 (live_page_test.dart), so across the felt
/// is Ada, on the left Dee and on the right Bao.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' show Phase;
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/net/in_use.dart';
import 'package:open_hearts/net/watching.dart';
import 'package:open_hearts/reaction_mute.dart';
import 'package:open_hearts/review_page.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/reactions.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'live_page_test.dart' show LiveHarness, pumpLive;

/// Everything said aloud while [body] runs, with how it was said.
Future<List<Map<Object?, Object?>>> _heard(WidgetTester tester, Future<void> Function() body) async {
  final said = <Map<Object?, Object?>>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (message) async {
    final m = message as Map;
    if (m['type'] == 'announce') said.add(m['data'] as Map);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));
  await body();
  return said;
}

/// Where [name]'s badge is drawn: not the copy laid out to size its
/// partner.
Rect _badge(WidgetTester tester, String name) {
  final drawn = find.byWidgetPredicate((w) => w is SeatBadge && w.name == name).evaluate().where((e) {
    var ghost = false;
    e.visitAncestorElements((a) {
      ghost = a.widget is BadgeGhost;
      return !ghost;
    });
    return !ghost;
  });
  final box = drawn.single.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

Finder _bubbleOf(String name) => find.byWidgetPredicate((w) => w is ReactionBubble && w.name == name);

/// What this player has told the table, as reactions.
List<ReactionSaid> _said(LiveHarness live) => [
      for (final s in live.reactions.said)
        if (s.from == live.keys[live.controller.mySeat]) ReactionSaid.decode(s.content)!,
    ];

void main() {
  // Measured in the font the screen is drawn in, as the large-text suite
  // does (fits.dart): Roboto, which the web build and Android draw in.
  setUpAll(() async {
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path}'
        '/bin/cache/artifacts/material_fonts';
    final roboto = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(File('$fonts/Roboto-$weight.ttf').readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await roboto.load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReactionMute.current.value = false;
  });
  tearDown(() {
    ReactionMute.current.value = false;
    InUse.current = InUse();
  });

  testWidgets('the button beside your badge offers six; one picked is said to the table and shows in its place, then the button is back',
      (tester) async {
    final live = await pumpLive(tester);
    final button = find.byType(ReactionButton);
    expect(button, findsOneWidget);
    expect(find.bySemanticsLabel('React'), findsOneWidget);
    // Beside the player's own badge, on the far side of it from the
    // left-hand seat: clear of the action line and the hand below.
    final you = _badge(tester, 'You');
    final at = tester.getRect(button);
    expect(at.left, greaterThanOrEqualTo(you.right));
    expect(at.center.dy, closeTo(you.center.dy, 1));

    await tester.tap(button);
    await tester.pumpAndSettle();
    for (final word in ['Nice', 'Ha', 'Wow', 'Ouch', 'Sorry', 'Good game']) {
      expect(find.text(word), findsOneWidget, reason: word);
    }
    for (final emoji in ['👍', '😂', '😮', '😬', '🙏', '👋']) {
      expect(find.text(emoji), findsOneWidget, reason: emoji);
    }
    expect(find.text('Hide others\' reactions'), findsOneWidget);

    await tester.tap(find.text('Ouch'));
    await tester.pumpAndSettle();
    expect(find.text('Good game'), findsNothing, reason: 'the picker is gone with the pick');
    // Said once, as a code and the moment: the first hand, no card yet.
    expect(live.reactions.said.single.from, live.keys[2]);
    expect(_said(live).single.reaction, Reaction.ouch);
    expect(_said(live).single.hand, 0);
    expect(_said(live).single.turn, 0);
    // Shown in the button's place, by the player's own badge.
    expect(_bubbleOf('You'), findsOneWidget);
    expect(button, findsNothing);
    expect(tester.getRect(_bubbleOf('You')).left, greaterThanOrEqualTo(you.right));

    // And at most one every three seconds, however it is asked for.
    live.controller.react(Reaction.nice);
    expect(live.reactions.said, hasLength(1));
    await live.advance(tester, 3000);
    expect(_bubbleOf('You'), findsNothing);
    expect(button, findsOneWidget, reason: 'the button is back');
    live.controller.react(Reaction.nice);
    expect(_said(live).map((s) => s.reaction), [Reaction.ouch, Reaction.nice]);
    await tester.pumpAndSettle();
    expect(_bubbleOf('You'), findsOneWidget);
    await live.advance(tester, 3000);
  });

  testWidgets('on the smallest phone at twice the type in German, the six and the switch are all on the screen, whole', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: Builder(builder: (context) => Scaffold(body: Center(child: ReactionButton(onPressed: () => pickReaction(context))))),
    ));
    await tester.tap(find.byType(ReactionButton));
    await tester.pumpAndSettle();
    final screen = Offset.zero & const Size(320, 568);
    for (final word in ['Stark', 'Haha', 'Wow', 'Autsch', 'Sorry', 'Gutes Spiel', 'Reaktionen der anderen ausblenden']) {
      final at = tester.getRect(find.text(word));
      expect(screen.contains(at.topLeft) && screen.contains(at.bottomRight - const Offset(0.5, 0.5)), isTrue, reason: '$word at $at');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen reader presses the button and picks, as a thumb does', (tester) async {
    final semantics = tester.ensureSemantics();
    final live = await pumpLive(tester);
    tester.semantics.tap(find.semantics.byLabel('React'));
    await tester.pumpAndSettle();
    tester.semantics.tap(find.semantics.byLabel('Wow'));
    await tester.pumpAndSettle();
    expect(_said(live).single.reaction, Reaction.wow);
    expect(find.bySemanticsLabel('You: Wow'), findsOneWidget);
    await live.advance(tester, 3000);
    semantics.dispose();
  });

  testWidgets('another player\'s reaction shows beside their badge, is said politely, and goes after three seconds', (tester) async {
    final live = await pumpLive(tester);
    late Rect bubble;
    final said = await _heard(tester, () async {
      live.reactFrom(1, Reaction.nice);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_bubbleOf('Bao'), findsOneWidget);
      bubble = tester.getRect(_bubbleOf('Bao'));
      expect(find.bySemanticsLabel('Bao: Nice'), findsOneWidget);
    });
    expect([for (final m in said) m['message']], contains('Bao: Nice'));
    expect(said.firstWhere((m) => m['message'] == 'Bao: Nice').containsKey('assertiveness'), isFalse,
        reason: 'polite: after whatever is being said, never over it');
    // Bao sits on the right: the bubble over his badge.
    final bao = _badge(tester, 'Bao');
    expect(bubble.bottom, lessThanOrEqualTo(bao.top));
    expect(bubble.center.dx, closeTo(bao.center.dx, bao.width / 2));

    await tester.pump(const Duration(milliseconds: 2900));
    expect(_bubbleOf('Bao'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(_bubbleOf('Bao'), findsNothing);
    await live.advance(tester, 3000);
  });

  testWidgets('one at every seat at once, each beside its own badge and clear of the cards and of each other', (tester) async {
    final live = await pumpLive(tester);
    for (final seat in [0, 1, 3]) {
      live.reactFrom(seat, Reaction.gg);
    }
    live.controller.react(Reaction.gg);
    await tester.pump();
    await tester.pumpAndSettle();
    final you = _badge(tester, 'You');
    final ada = _badge(tester, 'Ada');
    final dee = _badge(tester, 'Dee');
    final bao = _badge(tester, 'Bao');
    final mine = tester.getRect(_bubbleOf('You'));
    final across = tester.getRect(_bubbleOf('Ada'));
    final left = tester.getRect(_bubbleOf('Dee'));
    final right = tester.getRect(_bubbleOf('Bao'));
    // Across the felt, on the near side of the far badge; on the left,
    // under that badge; on the right, over it; and the player's own on
    // the far side of theirs from the left-hand seat's.
    expect(across.right, lessThanOrEqualTo(ada.left));
    expect(across.center.dy, closeTo(ada.center.dy, 1));
    expect(left.top, greaterThanOrEqualTo(dee.bottom));
    expect(right.bottom, lessThanOrEqualTo(bao.top));
    expect(mine.left, greaterThanOrEqualTo(you.right));
    final all = [mine, across, left, right, you, ada, dee, bao];
    for (var i = 0; i < all.length; i++) {
      for (var j = i + 1; j < all.length; j++) {
        expect(all[i].overlaps(all[j]), isFalse, reason: '$i and $j');
      }
    }
    await live.advance(tester, 3000);
  });

  testWidgets('nothing shows that is not a seated player\'s reaction, lately, about this hand, and not too soon after their last',
      (tester) async {
    final live = await pumpLive(tester);
    Future<void> settle() async {
      await tester.pump();
      await tester.pump();
    }

    final nowS = live.reactions.nowMs() ~/ 1000;
    String content(String code, {int hand = 0}) => '{"react":"$code","hand":$hand,"turn":0}';
    // A stranger on the tag; a code this screen does not know; words;
    // one said twenty seconds ago; one about the game's third hand.
    live.reactions.sayAs(FakeSigner('stranger').publicKey, content('nice'));
    live.reactions.sayAs(live.keys[1], content('lol'));
    live.reactions.sayAs(live.keys[1], 'hello, all of you');
    live.reactions.sayAs(live.keys[1], content('nice'), createdAt: nowS - 20);
    live.reactions.sayAs(live.keys[1], content('nice', hand: 2));
    await settle();
    expect(find.byType(ReactionBubble), findsNothing);
    // Bao's 😮, and a 😂 a moment later, which is a flood: the 😮 stays.
    live.reactFrom(1, Reaction.wow);
    await settle();
    live.reactFrom(1, Reaction.ha);
    await settle();
    expect(find.text('Wow'), findsOneWidget);
    expect(find.text('Ha'), findsNothing);
    await live.advance(tester, 3000);
    live.reactFrom(1, Reaction.ha);
    await settle();
    expect(find.text('Ha'), findsOneWidget);
    await live.advance(tester, 3000);
  });

  testWidgets('hidden: nobody else\'s shows or is said, the player\'s own still does, and the device remembers', (tester) async {
    final live = await pumpLive(tester);
    // The switch is under the six.
    await tester.tap(find.byType(ReactionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide others\' reactions'));
    await tester.pumpAndSettle();
    expect(ReactionMute.current.value, isTrue);
    // Away without a pick: the picker stays to be used.
    await tester.tapAt(const Offset(195, 60));
    await tester.pumpAndSettle();
    expect(find.text('Good game'), findsNothing);

    final said = await _heard(tester, () async {
      live.reactFrom(1, Reaction.nice);
      await tester.pump();
      await tester.pump();
      expect(find.byType(ReactionBubble), findsNothing);
      await tester.tap(find.byType(ReactionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sorry'));
      await tester.pumpAndSettle();
      expect(_bubbleOf('You'), findsOneWidget, reason: 'what the player did, they see');
    });
    expect([for (final m in said) m['message']], isNot(contains('Bao: Nice')));
    expect(_said(live).single.reaction, Reaction.sorry, reason: 'hidden is not silenced: the table hears it');

    // Kept on the device, for the next table and the next time.
    expect((await SharedPreferences.getInstance()).getBool('reactions_muted'), isTrue);
    final again = ReactionMute();
    await again.load();
    expect(again.value, isTrue);

    // Shown again.
    await live.advance(tester, 3000);
    await ReactionMute.current.set(false);
    live.reactFrom(1, Reaction.wow);
    await tester.pump();
    await tester.pump();
    expect(_bubbleOf('Bao'), findsOneWidget);
    await live.advance(tester, 3000);
  });

  testWidgets('a bot\'s seat says nothing: the key that sat there before is nobody\'s to show', (tester) async {
    final live = await pumpLive(tester, botSeats: {1});
    live.reactFrom(1, Reaction.nice);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ReactionBubble), findsNothing);
    await live.advance(tester, 3000);
  });

  testWidgets('a device the account was taken up from leaves its seat, and says nothing more', (tester) async {
    final live = await pumpLive(tester);
    expect(find.byType(ReactionButton), findsOneWidget);
    InUse.current.stepBack();
    await tester.pumpAndSettle();
    expect(find.byType(ReactionButton), findsNothing);
    live.controller.react(Reaction.nice);
    expect(live.reactions.said, isEmpty);
    await live.advance(tester, 1000);
  });

  testWidgets('alone, there is nothing to react with, and nothing reacts', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const TablePage(seed: 3)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TableView), findsOneWidget);
    expect(find.byType(ReactionButton), findsNothing);
    expect(find.byType(ReactionBubble), findsNothing);
  });

  testWidgets('watching, the players\' reactions show beside their names; a watcher has none to send, and can hide them', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 1200)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ada = FakeSigner('ada').publicKey;
    final bao = FakeSigner('bao').publicKey;
    const table = '0123456789abcdef0123456789abcdef';
    final watched = StreamController<Watched>();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: ReviewPage(table: table, load: (_) async => null, watch: (_) => watched.stream),
    ));
    await tester.pump();
    watched.add(Viewed(WatchedTable(
      table: table,
      target: 50,
      seq: 3,
      hand: 1,
      phase: Phase.playing,
      names: const ['Ada', 'Romeo', 'Bao', 'Juliet'],
      totals: const [0, 0, 0, 0],
      taken: const [0, 0, 0, 0],
      plays: const [],
      toPlay: 0,
      keys: [ada, null, bao, null],
    )));
    await tester.pump();
    expect(find.text('Live'), findsOneWidget);
    expect(find.byType(ReactionButton), findsNothing, reason: 'nobody watching sits at the table');

    var n = 0;
    Reacted from(PublicKey key, String code) => Reacted((
          from: key,
          id: 'e${n++}',
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          content: '{"react":"$code","hand":1,"turn":8}',
        ));
    final said = await _heard(tester, () async {
      watched.add(from(bao, 'gg'));
      // A key the view does not seat — another watcher, a stranger — is
      // shown nothing.
      watched.add(from(FakeSigner('someone watching').publicKey, 'nice'));
      await tester.pump();
      await tester.pump();
    });
    expect(_bubbleOf('Bao'), findsOneWidget);
    expect(find.byType(ReactionBubble), findsOneWidget);
    expect([for (final m in said) m['message']], ['Bao: Good game']);
    // In Bao's row, after his name.
    final row = tester.getRect(find.text('Bao'));
    expect(tester.getRect(_bubbleOf('Bao')).center.dy, closeTo(row.center.dy, 12));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(ReactionBubble), findsNothing);

    // Hidden here, and shown nothing.
    await tester.tap(find.text('Hide others\' reactions'));
    await tester.pump();
    expect(ReactionMute.current.value, isTrue);
    watched.add(from(ada, 'nice'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ReactionBubble), findsNothing);
    // The page asks for the record a few more times meanwhile.
    await tester.pump(const Duration(seconds: 10));
    unawaited(watched.close());
  });
}
