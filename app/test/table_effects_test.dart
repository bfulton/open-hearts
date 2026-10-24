/// What the felt does as points are taken (ui/table_view.dart): a seat's
/// badge glows from when it wins a trick with points in it until the
/// cards are in and a while after, pink, and red half a second longer
/// for the queen, in place of the white border a trick without points
/// gives its winner; and a moon, whoever shot it,
/// shakes the felt from the shooter's badge, with rings running out
/// from it, all over before the sheet comes down.
library;

import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/pacing.dart';
import 'package:open_hearts/table_model.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/overlays.dart';
import 'package:open_hearts/ui/player_icon.dart';
import 'package:open_hearts/ui/table_view.dart';

/// A table whose four seats are the engine's bots, moved a step at a
/// time by the test, which says when the felt hears of it.
class _Table extends ChangeNotifier implements TableModel {
  _Table(int seed, {this.mySeat = 0, this.people = const {}}) : game = HeartsGame(seed: seed);

  @override
  final HeartsGame game;

  @override
  final int mySeat;

  /// The seats played by people rather than bots, as a table has them:
  /// bots all the same, moved by the test, but with no persona.
  final Set<int> people;

  final _bots = [for (var s = 0; s < seatCount; s++) Bot(persona: Persona.roster[s])];
  final _played = <Card>{};

  /// One step of the game: the passes, a card, a trick taken, or the
  /// next hand dealt.
  void step() {
    switch (game.phase) {
      case Phase.passing:
        for (var s = 0; s < seatCount; s++) {
          if (!game.hasPassed(s)) game.setPass(s, _bots[s].choosePass(game.handOf(s)));
        }
      case Phase.handOver:
        game.nextHand();
        _played.clear();
      case Phase.playing when game.pendingTrick != null:
        game.collectTrick();
      case Phase.playing:
        final s = game.currentSeat!;
        final view = BotView(
          seat: s,
          hand: game.handOf(s),
          trick: game.trick,
          played: _played,
          heartsBroken: game.heartsBroken,
          isFirstTrick: game.isFirstTrick,
          taken: game.taken,
        );
        final card = _bots[s].chooseCard(view, game.legalPlaysFor(s));
        game.play(s, card);
        _played.add(card);
      case Phase.dealing || Phase.gameOver:
        throw StateError('nothing to step at ${game.phase}');
    }
  }

  /// Steps until [done], without the felt hearing of any of it.
  void stepUntil(bool Function(HeartsGame game) done) {
    for (var guard = 0; guard < 10000; guard++) {
      if (done(game)) return;
      step();
    }
    throw StateError('never came');
  }

  void tell() => notifyListeners();

  @override
  List<String> get names => const ['Ada', 'Bao', 'Cy', 'Dee'];
  @override
  Persona? personaAt(int seat) => people.contains(seat) ? null : _bots[seat].persona;
  @override
  Set<Card> get playedThisHand => _played;
  @override
  Set<Card> get selected => const {};
  @override
  bool get awaitingPass => false;
  @override
  bool get canConfirmPass => false;
  @override
  bool get awaitingPlay => false;
  @override
  Set<Card> get legalNow => const {};
  @override
  void toggleSelected(Card card) {}
  @override
  void confirmPass() {}
  @override
  String? playCard(Card card) => 'not here';
  @override
  Card? get pendingPlay => null;
  @override
  Set<Card> get inFlight => const {};
  @override
  String iconSeedOf(int seat) => names[seat];
  @override
  String iconNameOf(int seat) => names[seat];
  @override
  Avatar avatarOf(int seat) => Avatar.none;
  @override
  int? clockMs(int seat) => null;
  @override
  Set<Card> get passed => const {};
  @override
  bool get autoOffered => false;
  @override
  bool get autoPlay => false;
  @override
  void setAutoPlay(bool on) {}
  @override
  SeatReaction? reactionAt(int seat) => null;
  @override
  String nameAlone(int seat) => names[seat];
  @override
  int positionOf(int seat) => (seat - mySeat + seatCount) % seatCount;
  @override
  int seatAt(int position) => (position + mySeat) % seatCount;
}

/// The felt on a phone, rebuilt whenever [table] tells it, the device
/// asking for less motion when [still].
Future<void> _pump(WidgetTester tester, _Table table, {bool still = false}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: still), child: child!),
    home: Scaffold(
      body: ListenableBuilder(listenable: table, builder: (context, _) => TableView(controller: table)),
    ),
  ));
}

/// The trick on the table shown, then taken and shown taken: the frame
/// that starts what taking it sets off, and the one its clocks count
/// from.
Future<void> _take(WidgetTester tester, _Table table) async {
  expect(table.game.pendingTrick, isNotNull);
  table.tell();
  await tester.pump(const Duration(milliseconds: 500));
  table
    ..step()
    ..tell();
  await tester.pump();
  await tester.pump();
}

/// A table of seed [seed] one step before [done] holds of it: the felt
/// shown it there sees the step that makes it so.
_Table _before(int seed, bool Function(HeartsGame game) done) {
  final probe = _Table(seed);
  var steps = 0;
  for (; !done(probe.game); steps++) {
    probe.step();
  }
  final table = _Table(seed);
  for (var i = 0; i < steps - 1; i++) {
    table.step();
  }
  return table;
}

/// The last card of the trick played, and the felt told: the trick won.
Future<void> _win(WidgetTester tester, _Table table) async {
  table
    ..step()
    ..tell();
  expect(table.game.pendingTrick, isNotNull);
  await tester.pump();
}

/// The colour of the border of the badge at [position].
Color _border(WidgetTester tester, int position) {
  final box = tester.widget<AnimatedContainer>(find.descendant(of: find.byKey(pointsGlowAt(position)), matching: find.byType(AnimatedContainer)).first);
  return ((box.decoration! as BoxDecoration).border! as Border).top.color;
}

/// How strong the glow round the badge at [position] is: the alpha of
/// its bright edge, which is drawn at full strength's.
double _strength(WidgetTester tester, int position) {
  final glow = find.byKey(pointsGlowAt(position));
  final canvas = _Glows();
  tester.widget<CustomPaint>(glow).painter!.paint(canvas, tester.getSize(glow));
  return canvas.drawn.isEmpty ? 0 : canvas.drawn.first.colour.a;
}

/// The glow round the badge at [position]: its colour at full strength,
/// or null where there is none.
Color? _glow(WidgetTester tester, int position) {
  final glow = find.byKey(pointsGlowAt(position));
  final size = tester.getSize(glow);
  final canvas = _Glows();
  tester.widget<CustomPaint>(glow).painter!.paint(canvas, size);
  if (canvas.drawn.isEmpty) return null;
  final clip = canvas.clip!;
  expect(clip.contains(size.center(Offset.zero)), isFalse, reason: 'not through the badge');
  expect(clip.contains(Offset(size.width / 2, -3)), isTrue, reason: 'round it');
  expect(canvas.drawn.every((d) => d.blurred), isTrue, reason: 'a glow, not a band');
  final colours = {for (final d in canvas.drawn) d.colour.withValues(alpha: 1).toARGB32()};
  expect(colours, hasLength(1), reason: 'one colour');
  return Color(colours.single);
}

/// A canvas that keeps what a glow clips to and draws.
class _Glows implements Canvas {
  Path? clip;
  final drawn = <({Color colour, bool blurred})>[];

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) => clip = path;

  @override
  void drawRRect(RRect rrect, Paint paint) {
    expect(clip, isNotNull, reason: 'clipped before it is drawn');
    drawn.add((colour: paint.color, blurred: paint.maskFilter != null));
  }

  @override
  void save() {}

  @override
  void restore() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => fail('the glow drew something else: ${invocation.memberName}');
}

List<Color?> _glows(WidgetTester tester) => [for (var p = 0; p < seatCount; p++) _glow(tester, p)];

bool _hasQueen(({List<Play> plays, int winner}) trick) => trick.plays.any((p) => p.card == queenOfSpades);
int _points(({List<Play> plays, int winner}) trick) => pointsIn(trick.plays.map((p) => p.card));

/// A step comfortably past a frame.
const _frame = Duration(milliseconds: 40);

/// Long enough for the badge that took a trick to ease out of the
/// border it wore while it was on the table, which moves a side badge's
/// middle by a fraction of a point.
const _borderEases = Duration(milliseconds: 220);

void main() {
  group('points glow', () {
    testWidgets('pink round the winner as soon as the trick is won, for its white border, held through the sweep, and gone after',
        (tester) async {
      final table = _before(1, (g) => g.pendingTrick != null && _points(g.pendingTrick!) > 0 && !_hasQueen(g.pendingTrick!));
      await _pump(tester, table);
      expect(_glows(tester), everyElement(isNull), reason: 'nothing before the trick is won');
      await _win(tester, table);
      final taker = table.positionOf(table.game.pendingTrick!.winner);

      await tester.pump(Pacing.pointsGlow * 0.15 + _frame);
      expect(_glow(tester, taker), Palette.pink);
      expect([for (var p = 0; p < seatCount; p++) if (p != taker) _glow(tester, p)], everyElement(isNull), reason: 'the winner alone');
      expect(_border(tester, taker), isNot(Palette.chrome), reason: 'the glow says it, not a white border as well');
      final glow = find.byKey(pointsGlowAt(taker));
      expect(tester.widget<CustomPaint>(glow).painter!.hitTest(tester.getSize(glow).center(Offset.zero)), isFalse,
          reason: 'what is under it is touched, not it');
      await tester.pump(const Duration(milliseconds: 500));
      expect(_glow(tester, taker), Palette.pink, reason: 'held while the trick is on the table');

      await _take(tester, table);
      await tester.pump(Pacing.trickSweeps + Pacing.pointsGlow * 0.5 - _frame);
      expect(_strength(tester, taker), 1, reason: 'held through the sweep and half its time after');
      await tester.pump(Pacing.pointsGlow * 0.25);
      expect(_strength(tester, taker), allOf(greaterThan(0), lessThan(1)), reason: 'fading');
      await tester.pump(Pacing.pointsGlow * 0.25 + _frame * 2);
      expect(_glows(tester), everyElement(isNull), reason: 'gone once it has had its time');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('red for the queen, and half a second longer', (tester) async {
      final table = _before(1, (g) => g.pendingTrick != null && _hasQueen(g.pendingTrick!));
      await _pump(tester, table);
      await _win(tester, table);
      final taker = table.positionOf(table.game.pendingTrick!.winner);
      await tester.pump(Pacing.queenGlow * 0.15 + _frame);
      expect(_glow(tester, taker), Palette.red);
      expect(_border(tester, taker), isNot(Palette.chrome));

      await _take(tester, table);
      // Where a trick of hearts alone would be gone.
      await tester.pump(Pacing.trickSweeps + Pacing.pointsGlow + _frame);
      expect(_glow(tester, taker), Palette.red, reason: 'longer than points alone');
      expect(Pacing.queenGlow - Pacing.pointsGlow, const Duration(milliseconds: 500));
      await tester.pump(Pacing.queenGlow - Pacing.pointsGlow);
      expect(_glows(tester), everyElement(isNull));
    });

    testWidgets('none for a trick without points, whose winner has the white border', (tester) async {
      final table = _before(1, (g) => g.pendingTrick != null && _points(g.pendingTrick!) == 0);
      await _pump(tester, table);
      await _win(tester, table);
      final taker = table.positionOf(table.game.pendingTrick!.winner);
      await tester.pump(_borderEases);
      expect(_border(tester, taker), Palette.chrome);
      await tester.pump(const Duration(milliseconds: 500));
      await _take(tester, table);
      for (var t = Duration.zero; t < Pacing.trickSweeps + Pacing.queenGlow; t += const Duration(milliseconds: 100)) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(_glows(tester), everyElement(isNull));
      }
    });

    testWidgets('none for a trick taken that the felt never showed on the table', (tester) async {
      final table = _Table(1)..stepUntil((g) => g.phase == Phase.playing);
      await _pump(tester, table);
      // The felt sees the play begin, and next the first trick with
      // points in it already taken.
      table
        ..stepUntil((g) => g.pendingTrick != null && _points(g.pendingTrick!) > 0)
        ..step()
        ..tell();
      expect(table.game.taken.any((t) => t > 0), isTrue);
      await tester.pump();
      await tester.pump(Pacing.trickSweeps + Pacing.pointsGlow * 0.3);
      expect(_glows(tester), everyElement(isNull));
    });

    testWidgets('where the device asks for less motion, its time after starts as the trick is taken, nothing being swept',
        (tester) async {
      final table = _before(1, (g) => g.pendingTrick != null && _points(g.pendingTrick!) > 0 && !_hasQueen(g.pendingTrick!));
      await _pump(tester, table, still: true);
      await _win(tester, table);
      final taker = table.positionOf(table.game.pendingTrick!.winner);
      await tester.pump(Pacing.pointsGlow * 0.15 + _frame);
      expect(_glow(tester, taker), Palette.pink);
      await tester.pump(const Duration(milliseconds: 500));
      await _take(tester, table);
      await tester.pump(Pacing.pointsGlow * 0.5 - _frame);
      expect(_strength(tester, taker), 1);
      await tester.pump(Pacing.pointsGlow * 0.5 + _frame * 2);
      expect(_glows(tester), everyElement(isNull));
    });

    testWidgets('the same seat winning the next trick with points before the glow is gone glows on, not twice', (tester) async {
      final probe = _Table(1);
      // Two tricks with points in a row to the same seat: the step the
      // first is won at.
      int? last;
      var first = 0;
      for (var steps = 0;; steps++) {
        final g = probe.game;
        if (g.pendingTrick != null && _points(g.pendingTrick!) > 0) {
          if (last == g.pendingTrick!.winner) break;
          last = g.pendingTrick!.winner;
          first = steps;
        } else if (g.pendingTrick != null) {
          last = null;
        }
        probe.step();
      }
      final table = _Table(1);
      for (var i = 0; i < first; i++) {
        table.step();
      }
      final taker = table.positionOf(last!);
      final lasts = _hasQueen(table.game.pendingTrick!) ? Pacing.queenGlow : Pacing.pointsGlow;
      await _pump(tester, table);
      await tester.pump(lasts * 0.15 + _frame);
      await _take(tester, table);
      // The cards in, and its fade begun, when the next trick is won.
      await tester.pump(Pacing.trickSweeps + lasts * 0.75);
      final fading = _strength(tester, taker);
      expect(fading, allOf(greaterThan(0), lessThan(1)));
      table.stepUntil((g) => g.pendingTrick != null);
      expect(table.game.pendingTrick!.winner, last);
      table.tell();
      await tester.pump();
      expect(_strength(tester, taker), moreOrLessEquals(fading, epsilon: 0.05), reason: 'up again from where it was, not from nothing');
      await tester.pump(_frame);
      expect(_strength(tester, taker), greaterThan(fading));
      await tester.pump(Pacing.queenGlow);
      expect(_strength(tester, taker), 1, reason: 'and held while the trick is on the table');
    });
  });

  group('a moon', () {
    // Seed 3's first hand ends with seat 1 shooting the moon: the player
    // themself where they sit there, a bot on their left where they sit
    // at 0.
    for (final (mySeat, where) in [(1, 'you'), (0, 'the seat on your left')]) {
      testWidgets('shot by $where shakes the felt from the shooter, with rings from their badge, over before the sheet',
          (tester) async {
        final table = _Table(_moonSeed, mySeat: mySeat)..stepUntil((g) => g.tricksPlayed == 12 && g.pendingTrick != null);
        await _pump(tester, table);
        final shooter = table.positionOf(1);
        final away = -seatDirection[shooter]!;
        await _take(tester, table);
        expect(table.game.moonShooter, 1);

        // Still while the last trick is on its way to the shooter, once
        // the badge that took it has eased out of its border.
        await tester.pump(_borderEases);
        final rest = _centres(tester);
        await tester.pump(Pacing.trickSweeps - _borderEases - _frame);
        expect(_centres(tester), rest);
        expect(_rings(tester), isEmpty);
        await tester.pump(_frame);

        // Then shaken: every badge together, along the line from the
        // shooter, the first jolt away from them; and rings from the
        // shooter's badge as it was at rest, running out.
        final moves = <Offset>[];
        final rings = <List<({Offset c, double r})>>[];
        for (var t = Duration.zero; t < Pacing.moonQuake; t += const Duration(milliseconds: 20)) {
          await tester.pump(const Duration(milliseconds: 20));
          final now = _centres(tester);
          final move = now[0] - rest[0];
          for (var p = 1; p < seatCount; p++) {
            expect(now[p] - rest[p], _near(move), reason: 'the felt shakes as one');
          }
          moves.add(move);
          rings.add(_rings(tester));
        }
        final first = moves.firstWhere((m) => m.distance > 0.5);
        expect(first.dx * away.dx + first.dy * away.dy, greaterThan(0), reason: 'first away from the shooter');
        double along(Offset m) => (m.dx * away.dx + m.dy * away.dy).abs();
        double across(Offset m) => (m.dx * away.dy - m.dy * away.dx).abs();
        expect(moves.map(along).reduce(math.max), greaterThan(5), reason: 'a shake that is seen');
        expect(moves.map(along).fold(0.0, (a, b) => a + b), greaterThan(2 * moves.map(across).fold(0.0, (a, b) => a + b)));
        final drawn = rings.where((r) => r.isNotEmpty).toList();
        expect(drawn.length, greaterThan(10));
        for (final ring in drawn.expand((r) => r)) {
          expect(ring.c, _near(rest[shooter]), reason: "from the shooter's badge");
        }
        expect(drawn[3].map((r) => r.r).reduce(math.max), greaterThan(drawn[1].map((r) => r.r).reduce(math.max)), reason: 'running out');

        // And over: the felt where it was, before the sheet comes down.
        expect(Pacing.sweepBeat, greaterThanOrEqualTo(Pacing.trickSweeps + Pacing.moonQuake));
        await tester.pump(_frame);
        expect(_centres(tester), rest);
        expect(_rings(tester), isEmpty);
        await tester.pump(Pacing.queenGlow);
        expect(tester.binding.hasScheduledFrame, isFalse);
      });
    }

    testWidgets('the rings are under everything on the felt, and a touch goes through them', (tester) async {
      final table = _Table(_moonSeed)..stepUntil((g) => g.tricksPlayed == 12 && g.pendingTrick != null);
      await _pump(tester, table);
      await _take(tester, table);
      await tester.pump(Pacing.trickSweeps + Pacing.moonQuake * 0.3);
      final paint = tester.widget<CustomPaint>(_ringsFinder);
      expect(paint.foregroundPainter, isNull);
      expect(paint.painter!.hitTest(tester.getCenter(_ringsFinder)), isFalse);
      expect(_rings(tester), isNotEmpty);
    });

    testWidgets('a hand without one is not shaken', (tester) async {
      final table = _Table(1)..stepUntil((g) => g.tricksPlayed == 12 && g.pendingTrick != null);
      await _pump(tester, table);
      await _take(tester, table);
      expect(table.game.moonShooter, isNull);
      await tester.pump(_borderEases);
      final rest = _centres(tester);
      for (var t = _borderEases; t < Pacing.trickSweeps + Pacing.moonQuake; t += const Duration(milliseconds: 50)) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(_centres(tester), rest);
        expect(_rings(tester), isEmpty);
      }
    });

    testWidgets('one already on the felt when it opens is not shaken again', (tester) async {
      final table = _Table(_moonSeed)..stepUntil((g) => g.phase == Phase.handOver);
      expect(table.game.moonShooter, 1);
      await _pump(tester, table);
      final rest = _centres(tester);
      table.tell();
      for (var t = Duration.zero; t < Pacing.trickSweeps + Pacing.moonQuake; t += const Duration(milliseconds: 50)) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(_centres(tester), rest);
        expect(_rings(tester), isEmpty);
      }
    });

    testWidgets('nothing where the device asks for less motion', (tester) async {
      final table = _Table(_moonSeed)..stepUntil((g) => g.tricksPlayed == 12 && g.pendingTrick != null);
      await _pump(tester, table, still: true);
      await _take(tester, table);
      expect(table.game.moonShooter, 1);
      await tester.pump(_borderEases);
      final rest = _centres(tester);
      for (var t = _borderEases; t < Pacing.trickSweeps + Pacing.moonQuake; t += const Duration(milliseconds: 50)) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(_centres(tester), rest);
        expect(_rings(tester), isEmpty);
      }
    });
  });

  group('bots told from people', () {
    // The badge on the felt, not the ghosts of it the layout sizes by.
    Finder badgeOf(int seat) => find.byElementPredicate(
        (e) => e.widget is SeatBadge && (e.widget as SeatBadge).seat == seat && e.findAncestorWidgetOfExactType<BadgeGhost>() == null);
    Finder markOn(int seat) => find.descendant(of: badgeOf(seat), matching: find.byType(BotMark));
    Finder robotOn(int seat) => find.descendant(of: markOn(seat), matching: find.byIcon(Icons.smart_toy));

    testWidgets('a bot wears the mark and is said to be one; a person is neither', (tester) async {
      final table = _Table(3, people: {0, 2});
      await _pump(tester, table);
      expect(markOn(0), findsNothing, reason: 'your own seat');
      expect(markOn(2), findsNothing, reason: 'another person');
      expect(markOn(1), findsOneWidget);
      expect(markOn(3), findsOneWidget);
      expect(find.descendant(of: find.byType(TableView), matching: find.byIcon(Icons.smart_toy)).hitTestable(), findsNWidgets(2));
      expect(find.bySemanticsLabel(RegExp(r'^Bao, a bot: ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Dee, a bot: ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Cy: ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r', a bot')), findsNWidgets(2));
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets("the mark sits at the icon's lower right, mostly outside it, at ${scale}x type", (tester) async {
        // At the reader's own text size the mark stays the icon's size:
        // it is a mark on the icon, and the name beside it is what grows.
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _pump(tester, _Table(3, people: {0}));
        final icon = tester.getRect(find.descendant(of: badgeOf(1), matching: find.byType(PlayerIcon)));
        final disc = tester.getRect(find.ancestor(of: robotOn(1), matching: find.byType(Container)).first);
        expect(disc.width, lessThanOrEqualTo(icon.width * 0.42), reason: 'small beside the icon');
        expect(disc.width, moreOrLessEquals(disc.height));
        final apart = disc.center - icon.center;
        expect(apart.dx, moreOrLessEquals(apart.dy, epsilon: 0.5), reason: 'on the diagonal');
        expect(apart.dx, greaterThan(0), reason: 'to the lower right');
        // Its centre past the icon's rim, and its edge over it: it
        // touches the icon, and covers little of it.
        expect(apart.distance, greaterThan(icon.width / 2));
        expect(apart.distance, lessThan(icon.width / 2 + disc.width / 2));
      });
    }

    testWidgets('touched, the mark says it is a bot', (tester) async {
      await _pump(tester, _Table(3, people: {0}));
      expect(find.text('Bot'), findsNothing);
      await tester.tap(robotOn(1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Bot'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Bot'), findsNothing, reason: 'and goes again');
    });

    testWidgets('the score sheets mark the same seats, and say so', (tester) async {
      final table = _Table(3, people: {0, 2});
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HandOverSheet(handNumber: 0, scores: const [3, 8, 2, 13], totals: const [3, 8, 2, 13], moonShooter: null, seats: table.looks, onNext: () {}),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(BotMark), findsNWidgets(2));
      expect(find.bySemanticsLabel(RegExp(r'^Bao, a bot: ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Dee, a bot: ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Cy: ')), findsOneWidget);
    });

    testWidgets('four people, no mark', (tester) async {
      await _pump(tester, _Table(3, people: {0, 1, 2, 3}));
      expect(find.byType(BotMark), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r', a bot')), findsNothing);
    });
  });
}

/// A deal whose first hand, played by the bots, ends with seat 1
/// shooting the moon.
const _moonSeed = 3;

/// Where each position's badge is on screen.
List<Offset> _centres(WidgetTester tester) => [for (var p = 0; p < seatCount; p++) tester.getCenter(find.byKey(pointsGlowAt(p)))];

/// The felt's own painting, under everything on it: the quake's rings.
final _ringsFinder = find.descendant(of: find.byType(TableView), matching: find.byType(CustomPaint)).first;

/// The rings drawn now: where each is centred, and how far out it is.
List<({Offset c, double r})> _rings(WidgetTester tester) {
  final canvas = _Circles();
  tester.widget<CustomPaint>(_ringsFinder).painter!.paint(canvas, tester.getSize(_ringsFinder));
  return canvas.drawn;
}

Matcher _near(Offset o) => predicate<Offset>((x) => (x - o).distance < 0.01, 'within 0.01 of $o');

/// A canvas that keeps the circles drawn on it.
class _Circles implements Canvas {
  final drawn = <({Offset c, double r})>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    expect(paint.style, PaintingStyle.stroke);
    expect(paint.color.withValues(alpha: 1).toARGB32(), Palette.chrome.toARGB32());
    drawn.add((c: c, r: radius));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => fail('the rings drew something else: ${invocation.memberName}');
}
