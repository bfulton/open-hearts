/// The table at the reader's own text size (WCAG 1.4.4): a game alone
/// and a live one, through every phase they have, on the smallest phone
/// and the largest desktop, with the type at up to twice its size and
/// in every language the app speaks — and nothing overflowing, nothing
/// cut short, and nothing drawn over anything else.
///
/// Every combination of the four would be a thousand games, so the
/// matrix is chosen: every size at every text scale, the language
/// turning with them so each scale meets each language; German, the
/// longest, at twice the type on every size; and French beside it on
/// the phones where width is scarcest. The live table is slower to
/// drive, so it takes the largest type on every size and a few of the
/// rest (see [_live]).
///
/// The matrix, and what it checks; the suites that run it are
/// table_fits_test.dart (phones upright), table_fits_wide_test.dart
/// (everything wider), table_fits_live_test.dart (a hand) and
/// table_fits_live_end_test.dart (to the game's end).
library;

import 'dart:io';

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/live/live_page.dart';
import 'package:open_hearts/table_model.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/card_view.dart';
import 'package:open_hearts/ui/gone.dart';
import 'package:open_hearts/ui/hand_fan.dart';
import 'package:open_hearts/ui/header.dart';
import 'package:open_hearts/ui/overlays.dart';
import 'package:open_hearts/ui/pip.dart';
import 'package:open_hearts/ui/player_icon.dart';
import 'package:open_hearts/ui/reactions.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart' show Reaction;

import 'live_page_test.dart' show LiveHarness;

/// The shapes docs/explanation/screens.md names, and the two smallest
/// phones anyone still plays on.
const _sizes = [
  Size(320, 568),
  Size(360, 640),
  Size(390, 844),
  Size(844, 390),
  Size(768, 1024),
  Size(1280, 800),
  Size(1920, 1080),
];

const _scales = [1.0, 1.3, 1.5, 2.0];

final _languages = [for (final l in AppLocalizations.supportedLocales) l.languageCode];

String _name(Size size) => '${size.width.toInt()}x${size.height.toInt()}';

/// The solo matrix: every size at every scale, the language turning so
/// that each scale meets each language; and German at twice the type
/// on every size, French too on the narrow phones and the phone on its
/// side.
List<(Size, double, String)> get _solo {
  final cases = <(Size, double, String)>{};
  for (var i = 0; i < _sizes.length; i++) {
    for (var j = 0; j < _scales.length; j++) {
      cases.add((_sizes[i], _scales[j], _languages[(i + j) % _languages.length]));
    }
    cases.add((_sizes[i], 2.0, 'de'));
  }
  for (final size in [const Size(320, 568), const Size(360, 640), const Size(844, 390)]) {
    cases.add((size, 2.0, 'fr'));
  }
  return cases.toList();
}

/// The live matrix: German at twice the type on every size, and the
/// narrow phones and the phone on its side at the scales between, in
/// the languages that run long.
List<(Size, double, String)> get _live => [
      for (final size in _sizes) (size, 2.0, 'de'),
      (const Size(320, 568), 1.5, 'fr'),
      (const Size(360, 640), 1.3, 'es'),
      (const Size(844, 390), 1.5, 'pt'),
      (const Size(390, 844), 1.0, 'en'),
    ];

/// The app as main.dart builds it, in [locale], with the type at
/// [scale], on a screen [size] big. No animation: what is under test is
/// where everything comes to rest.
Future<void> _pump(WidgetTester tester, Widget home, {required Size size, required double scale, required String locale}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: Locale(locale),
    home: Builder(
      builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: home),
    ),
  ));
}

/// Every error the framework reports while [body] runs: a RenderFlex
/// that overflows is one.
Future<List<String>> _errors(Future<void> Function() body) async {
  final errors = <String>[];
  final reported = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.toString().split('\n').take(8).join(' | '));
  try {
    await body();
  } finally {
    FlutterError.onError = reported;
  }
  return errors;
}

// ---- what is on the screen -----------------------------------------------

/// Whether [e] is drawn: not a copy of a badge laid out to size its
/// partner, not offstage, not hidden, not faded out.
bool _shown(Element e) {
  var shown = true;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is BadgeGhost || w is Offstage && w.offstage || w is Visibility && !w.visible || w is Opacity && w.opacity == 0) {
      shown = false;
    }
    return shown;
  });
  return shown;
}

/// Where [e] is drawn on the screen, transforms and all.
Rect? _rect(Element e) {
  final box = e.renderObject;
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
}

bool _inside(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 && inner.top >= outer.top - 0.5 && inner.right <= outer.right + 0.5 && inner.bottom <= outer.bottom + 0.5;

bool _over(Rect a, Rect b) {
  final i = a.intersect(b);
  return i.width > 0.5 && i.height > 0.5;
}

String _r(Rect r) => '(${r.left.toStringAsFixed(1)}, ${r.top.toStringAsFixed(1)}, ${r.width.toStringAsFixed(1)}×${r.height.toStringAsFixed(1)})';

/// A thing on the screen, as the checks name it.
typedef _Thing = ({String what, Rect rect, Element element});

Iterable<_Thing> _things(Finder finder, String Function(Element) what) => _each(finder.evaluate(), what);

Iterable<_Thing> _each(Iterable<Element> elements, String Function(Element) what) sync* {
  for (final e in elements) {
    if (!_shown(e)) continue;
    final r = _rect(e);
    if (r == null || r.isEmpty) continue;
    yield (what: what(e), rect: r, element: e);
  }
}

/// What under [root] is a widget [test] picks out.
List<Element> _under(Element root, bool Function(Widget) test) {
  final found = <Element>[];
  void visit(Element e) {
    if (test(e.widget)) found.add(e);
    e.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found;
}

/// The lines of text among [elements]: not an icon's glyph, which is
/// drawn as text and is a picture.
Iterable<_Thing> _texts(Iterable<Element> elements) =>
    _each(elements.where((e) => !_within(e, (w) => w is Icon)), (e) => '"${_textOf(e)}"');

String _textOf(Element e) => (e.renderObject! as RenderParagraph).text.toPlainText();

bool _within(Element e, bool Function(Widget) test) {
  var found = false;
  e.visitAncestorElements((a) {
    found = test(a.widget);
    return !found;
  });
  return found;
}

/// Nothing in [things] over anything else in it.
void _apart(List<_Thing> things, List<String> faults, String where) {
  for (var i = 0; i < things.length; i++) {
    for (var j = i + 1; j < things.length; j++) {
      if (_over(things[i].rect, things[j].rect)) {
        faults.add('$where: ${things[i].what} ${_r(things[i].rect)} over ${things[j].what} ${_r(things[j].rect)}');
      }
    }
  }
}

/// Whether [badge] would cut the name in [p] at ordinary type too: in
/// the room it has for a name, its width less its padding and, on one
/// line, its icon (ui/table_view.dart, SeatBadge._badge).
bool _cutAtOrdinary(RenderParagraph p, SeatBadge badge) {
  final room = badge.maxWidth - (badge.oneLine ? 20 + badge.iconSize + 6 : 22);
  return (TextPainter(text: p.text, textDirection: p.textDirection, maxLines: p.maxLines, ellipsis: '…')..layout(maxWidth: room))
      .didExceedMaxLines;
}

SeatBadge? _badgeOf(Element e) {
  SeatBadge? badge;
  e.visitAncestorElements((a) {
    if (a.widget is SeatBadge) badge = a.widget as SeatBadge;
    return badge == null;
  });
  return badge;
}

/// Everything wrong with the screen as it stands: each line one fault.
List<String> _faults(WidgetTester tester, String where, {Iterable<String> names = const []}) {
  final faults = <String>[];
  final screen = Offset.zero & tester.view.physicalSize;
  final sheet = find.byWidgetPredicate((w) => w is HandOverSheet || w is GameOverSheet);
  final sheetUp = sheet.evaluate().isNotEmpty;

  // Every line of text: whole, in its own box, on the screen.
  for (final t in _texts(find.byType(RichText).evaluate())) {
    final p = t.element.renderObject! as RenderParagraph;
    final text = _textOf(t.element);
    if (text.trim().isEmpty) continue;
    // A sheet scrolls, so what is past the screen's edge is on it.
    if (!_within(t.element, (w) => w is HandOverSheet || w is GameOverSheet) && !_inside(t.rect, screen)) {
      faults.add('$where: ${t.what} off the screen at ${_r(t.rect)}');
    }
    if (p.textSize.width > p.size.width + 0.5 || p.textSize.height > p.size.height + 0.5) {
      faults.add('$where: ${t.what} runs out of its box: ${p.textSize} in ${p.size}');
    }
    // A player's name is theirs, not a translation, and the table gives
    // a long one way on purpose (ui/table_view.dart, ui/overlays.dart).
    // A badge, though, cuts one at the reader's type only where it would
    // at ordinary type too: the badge's room grows with the type.
    final badge = _badgeOf(t.element);
    if (p.didExceedMaxLines && !(names.contains(text) && (badge == null || _cutAtOrdinary(p, badge)))) {
      faults.add('$where: ${t.what} cut short');
    }
    if (p.getMinIntrinsicWidth(double.infinity) > p.size.width + 0.5 && !p.didExceedMaxLines) {
      faults.add('$where: ${t.what} broken mid-word in ${p.size.width.toStringAsFixed(1)}');
    }
  }

  // Each card's corner — its rank and its suit — on the card.
  for (final card in _things(find.byType(CardView), (e) => (e.widget as CardView).card.code)) {
    for (final part in [
      ..._each(_under(card.element, (w) => w is RichText), (e) => 'rank'),
      ..._each(_under(card.element, (w) => w is Pip), (e) => 'pip'),
    ]) {
      // The big faint pip hangs off the corner on purpose, clipped by
      // the card: only the corner's own pip is the card's to keep.
      if (part.what == 'pip' && part.rect.width > card.rect.width * 0.5) continue;
      if (!_inside(part.rect, card.rect)) faults.add('$where: ${card.what}\'s ${part.what} ${_r(part.rect)} off the card ${_r(card.rect)}');
      // And at the card's own size, whatever the reader's type: in a fan
      // only the corner the next card leaves shows the rank, and a rank
      // that grew would grow under it.
      if (part.what == 'rank' && part.rect.height > card.rect.width * 0.4 + 0.5) {
        faults.add('$where: ${card.what}\'s rank ${_r(part.rect)} bigger than the card draws it');
      }
    }
  }

  if (sheetUp) {
    // Over the table, so the sheet is what there is to read.
    final inSheet = <_Thing>[
      ..._texts(find.descendant(of: sheet, matching: find.byType(RichText)).evaluate())
          .where((t) => !_within(t.element, (w) => w is ButtonStyleButton || w is PlayerIcon)),
      ..._things(find.descendant(of: sheet, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)), (e) => 'a button'),
      ..._things(find.descendant(of: sheet, matching: find.byType(PlayerIcon)), (e) => 'an icon'),
    ];
    _apart(inSheet, faults, where);
    return faults;
  }

  // The parts of the table, each in its own place: and beside it, where
  // there is room for one, the rail.
  final header = _things(find.byType(TableHeader), (e) => 'the header').firstOrNull;
  final felt = _things(find.byType(TableView), (e) => 'the felt').firstOrNull;
  final action = _things(find.byType(ActionBar), (e) => 'the action line').firstOrNull;
  final hand = _things(find.byType(HandFan), (e) => 'the hand').firstOrNull;
  final rail = _things(find.byType(Gone), (e) => 'the rail').firstOrNull;
  final parts = [?header, ?felt, ?action, ?hand, ?rail];
  _apart(parts, faults, where);
  for (final p in parts) {
    if (!_inside(p.rect, screen)) faults.add('$where: ${p.what} off the screen at ${_r(p.rect)}');
  }

  // The header: the menu, the line, the heart.
  if (header != null) {
    final inHeader = [
      ..._things(find.descendant(of: find.byType(TableHeader), matching: find.byType(MenuButton)), (e) => 'the menu'),
      ..._texts(find.descendant(of: find.byType(TableHeader), matching: find.byType(RichText)).evaluate()),
      ..._things(find.descendant(of: find.byType(TableHeader), matching: find.byType(Icon)), (e) => 'the heart')
          .where((t) => !_within(t.element, (w) => w is MenuButton)),
    ];
    _apart(inHeader, faults, where);
    for (final t in inHeader) {
      if (!_inside(t.rect, header.rect)) faults.add('$where: ${t.what} ${_r(t.rect)} out of the header ${_r(header.rect)}');
    }
  }

  // The felt: the badges, the trick, the line the table says, and at a
  // live table who is here.
  if (felt != null) {
    final badges = _things(find.byType(SeatBadge), (e) => '${(e.widget as SeatBadge).name}\'s badge').toList();
    final trick = _things(find.descendant(of: find.byType(TableView), matching: find.byType(CardView)),
        (e) => 'the ${(e.widget as CardView).card.code} on the felt').toList();
    final said = _things(find.descendant(of: find.byType(TableView), matching: find.byType(Announced)), (e) => 'what the table says')
        .map((t) {
      // The pill itself, round its words.
      final pill = _under(t.element, (w) => w is Container).first;
      return (what: '"${_textOf(_under(t.element, (w) => w is RichText).first)}"', rect: _rect(pill)!, element: pill);
    }).toList();
    final presence = _things(find.byType(FeltCorner), (e) => 'who is here').toList();
    // The players' reactions beside their badges, and the button beside
    // the player's own (ui/reactions.dart): on the felt, clear of every
    // badge, card and line on it and of each other.
    final reactions = [
      ..._things(find.descendant(of: find.byType(TableView), matching: find.byType(ReactionBubble)),
          (e) => '${(e.widget as ReactionBubble).name}\'s reaction'),
      ..._things(find.descendant(of: find.byType(TableView), matching: find.byType(ReactionButton)), (e) => 'the react button'),
    ];
    for (final t in [...badges, ...trick, ...said, ...presence, ...reactions]) {
      if (!_inside(t.rect, felt.rect)) faults.add('$where: ${t.what} ${_r(t.rect)} off the felt ${_r(felt.rect)}');
    }
    _apart([...badges, ...said, ...presence, ...reactions], faults, where);
    for (final card in trick) {
      _apart([card, ...badges], faults, where);
      _apart([card, ...said], faults, where);
      _apart([card, ...presence], faults, where);
      _apart([card, ...reactions], faults, where);
    }
    // What is on a badge stays on it: the icon, the name, the numbers,
    // the hearts and the clock.
    for (final b in badges) {
      final on = _under(b.element, (w) => w is RichText || w is Pip || w is PlayerIcon || w is ClockText)
          .where((e) => !_within(e, (w) => w is Icon));
      for (final t in _each(on, (e) => e.widget.runtimeType.toString())) {
        if (!_inside(t.rect, b.rect)) faults.add('$where: ${b.what}\'s ${t.what} ${_r(t.rect)} off it ${_r(b.rect)}');
      }
    }
  }

  // The action line: its words, its cards, its buttons and the switch,
  // each clear of the others and all of them on the line.
  if (action != null) {
    bool unit(Widget w) => w is ButtonStyleButton || w is AutoSwitch || w is CardChip;
    final inLine = [
      ..._things(find.descendant(of: find.byType(ActionBar), matching: find.byWidgetPredicate(unit)), (e) => e.widget.runtimeType.toString()),
      ..._texts(find.descendant(of: find.byType(ActionBar), matching: find.byType(RichText)).evaluate())
          .where((t) => !_within(t.element, unit)),
      ..._things(find.descendant(of: find.byType(ActionBar), matching: find.byType(Icon)), (e) => 'an icon')
          .where((t) => !_within(t.element, unit)),
    ];
    _apart(inLine, faults, where);
    for (final t in inLine) {
      if (!_inside(t.rect, action.rect)) faults.add('$where: ${t.what} ${_r(t.rect)} off the action line ${_r(action.rect)}');
    }
  }

  return faults;
}

// ---- the walks -------------------------------------------------------------

/// The screen checked once in each situation a game comes to.
class _Walk {
  _Walk(this.tester, this.names);

  final WidgetTester tester;

  /// The players' names, which a badge or a line may cut short.
  final List<String> Function() names;
  final faults = <String>[];
  final seen = <String>{};

  /// Checks the screen, the first time the game is in [situation].
  void look(String situation) {
    if (seen.add(situation)) faults.addAll(_faults(tester, situation, names: names()));
  }

  /// The faults, each once, with every situation it was found in.
  List<String> get report {
    final where = <String, List<String>>{};
    for (final f in faults) {
      final at = f.indexOf(': ');
      where.putIfAbsent(f.substring(at + 2), () => []).add(f.substring(0, at));
    }
    return [for (final MapEntry(:key, :value) in where.entries) '$key  [${value.join(', ')}]'];
  }
}

/// The situations that last less than a second.
const _fleeting = {'passed, waiting', 'a trick taken'};

/// What the table is doing, as far as its layout goes.
String _situation(TableModel c) {
  final g = c.game;
  if (c.awaitingPass) return c.selected.length == engine.passSize ? 'ready to pass' : 'choosing the pass';
  if (g.phase == engine.Phase.passing) return 'passed, waiting';
  if (g.pendingTrick != null) return 'a trick taken';
  if (c.awaitingPlay) return c.autoOffered ? 'Auto offered' : (g.tricksPlayed == 0 ? 'your first turn' : 'your turn');
  return g.trick.isEmpty ? 'others to lead' : 'others playing';
}

/// What every walk comes to on its way through a hand.
const _phases = {'choosing the pass', 'ready to pass', 'passed, waiting', 'your first turn', 'a trick taken', 'Auto offered'};

bool _sheetUp() => find.byWidgetPredicate((w) => w is HandOverSheet || w is GameOverSheet).evaluate().isNotEmpty;

/// Plays the next step for the player: a card more for the pass, the
/// pass, the first legal card, or once it is offered, Auto. Whether
/// anything was done that wants the table to move.
bool _act(TableModel c) {
  if (c.awaitingPass) {
    if (c.selected.length < engine.passSize) {
      c.toggleSelected(c.handShown.firstWhere((x) => !c.selected.contains(x)));
      return false;
    }
    c.confirmPass();
  } else if (c.awaitingPlay) {
    if (c.autoOffered) {
      c.setAutoPlay(true);
    } else {
      c.playCard(c.handShown.firstWhere(c.legalNow.contains));
    }
  }
  return true;
}

/// A deal whose first hand, played by the first legal card, comes to
/// the Auto switch with five cards still to play (autopilot_test.dart).
const _soloDeal = 156;

/// A game alone, at the table's own pace, from the pass to the hand's
/// sheet; and another, to a single point, to the game's.
Future<List<String>> _walkSolo(WidgetTester tester, {required Size size, required double scale, required String locale}) async {
  late _Walk walk;
  final errors = await _errors(() async {
    await _pump(tester, const TablePage(seed: _soloDeal), size: size, scale: scale, locale: locale);
    await tester.pump(const Duration(seconds: 1));
    final c = tester.widget<TableView>(find.byType(TableView)).controller;
    walk = _Walk(tester, () => c.names);
    // Alone, nobody reacts: no button, and bots say nothing.
    expect(find.byType(ReactionButton), findsNothing);
    for (var step = 0; step < 3000 && !_sheetUp(); step++) {
      walk.look(_situation(c));
      if (!_act(c)) {
        await tester.pump();
        continue;
      }
      // In short steps until the two moments that pass in under a
      // second have each been seen — the pass on its way, a trick on
      // the felt — and in longer ones after; and the fan's cards to
      // their places, which they slide to whatever else moves.
      await tester.pump(Duration(milliseconds: walk.seen.containsAll(_fleeting) ? 1000 : 250));
      await tester.pumpAndSettle();
    }
    expect(_sheetUp(), isTrue, reason: 'the hand came to its end');
    walk.look('hand over');

    // One to a single point is over with its first hand, and that is
    // the whole of what the game's sheet needs.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, const TablePage(key: ValueKey('to one'), seed: _soloDeal, paced: false, target: 1),
        size: size, scale: scale, locale: locale);
    await tester.pumpAndSettle();
    final end = tester.widget<TableView>(find.byType(TableView)).controller;
    for (var step = 0; step < 400 && end.game.phase != engine.Phase.gameOver; step++) {
      _act(end);
      await tester.pumpAndSettle();
    }
    expect(_sheetUp(), isTrue, reason: 'the game came to its end');
    walk.look('game over');
  });
  expect(walk.seen, containsAll({..._phases, 'hand over', 'game over'}), reason: 'the walk went through every phase');
  return [...errors, ...walk.report];
}

/// A live deal whose first hand, played by the first legal card, comes
/// to the Auto switch with four cards still to play.
const _liveDeal = 3;

/// A live table on the protocol's clock, from the pass to the end of
/// the first hand: its sheet, or [toTheEnd], the game's. On the way the
/// seat on the left dawdles over her first card, long enough for her
/// clock to show on her badge and the Boot to be offered on the line.
Future<List<String>> _walkLive(WidgetTester tester, {required Size size, required double scale, required String locale, required bool toTheEnd}) async {
  late _Walk walk;
  final errors = await _errors(() async {
    final live = LiveHarness(seed: _liveDeal, target: toTheEnd ? 1 : engine.gameOverScore, rated: toTheEnd);
    await _pump(tester, LivePage(controller: live.controller), size: size, scale: scale, locale: locale);
    await tester.pumpAndSettle();
    final c = live.controller;
    walk = _Walk(tester, () => c.names);
    live.people[0]!.thinkMs = 17000;
    for (var step = 0; step < 4000 && !_sheetUp(); step++) {
      if (_reactAround(live)) {
        await tester.pump();
        await tester.pump();
      }
      final situation = _situation(c);
      walk.look(situation);
      // And each moment again as it is with the player's own reaction
      // up, or the button in its place.
      walk.look('$situation · ${c.reactionAt(c.mySeat) == null ? 'the button' : 'your reaction'}');
      if (c.clockMs(0) != null) walk.look('a clock on a badge');
      if (c.canBoot(0)) {
        walk.look('Boot offered');
        live.people[0]!.thinkMs = 300;
      }
      if (!_act(c)) {
        await tester.pump();
        continue;
      }
      live.clock.advance(250);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
    }
    expect(_sheetUp(), isTrue, reason: 'the hand came to its end');
    walk.look(toTheEnd ? 'game over' : 'hand over');
  });
  expect(walk.seen, containsAll({..._phases, 'a clock on a badge', 'Boot offered', toTheEnd ? 'game over' : 'hand over'}),
      reason: 'the walk went through every phase');
  expect(walk.seen.where((s) => s.endsWith(' · your reaction')), isNotEmpty, reason: 'seen with a reaction at every seat');
  expect(walk.seen.where((s) => s.endsWith(' · the button')), isNotEmpty, reason: 'seen with the button beside the player');
  return [...errors, ...walk.report];
}

/// A reaction up at every seat (ui/reactions.dart), the longest word
/// there is in each: the others' said again as each goes, and the
/// player's own every other three seconds, so that the table is seen
/// with all four up and with three and the button. Whether anything
/// was said.
bool _reactAround(LiveHarness live) {
  final c = live.controller;
  var said = false;
  for (var seat = 0; seat < engine.seatCount; seat++) {
    if (seat == c.mySeat || c.reactionAt(seat) != null) continue;
    live.reactFrom(seat, Reaction.gg);
    said = true;
  }
  if (c.reactionAt(c.mySeat) == null && (live.clock.nowMs ~/ 3000).isEven && c.canReact) {
    c.react(Reaction.gg);
    said = true;
  }
  return said;
}

// ---- the suites --------------------------------------------------------------

/// What every suite of the matrix needs first. Measured in the font the
/// screen is drawn in, as l10n_test.dart does: Roboto, which the web
/// build and Android draw in. The other suites draw in the test font, a
/// square a letter, which is wider still (autopilot_test.dart).
void _setUp() {
  setUpAll(() async {
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path}'
        '/bin/cache/artifacts/material_fonts';
    final roboto = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(File('$fonts/Roboto-$weight.ttf').readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await roboto.load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({'identity_name': 'Ada'}));
}

/// The games alone, on the screens [shown] picks out of the matrix: the
/// matrix runs as a few suites, side by side, rather than one long one.
void soloMatrix(bool Function(Size size) shown) {
  _setUp();
  for (final (size, scale, locale) in _solo.where((c) => shown(c.$1))) {
    testWidgets('alone, ${_name(size)}, $locale, text ×$scale', (tester) async {
      final faults = await _walkSolo(tester, size: size, scale: scale, locale: locale);
      expect(faults, isEmpty, reason: faults.join('\n'));
    });
  }
}

/// The live games: every other one to the game's end, rated, for the
/// game's sheet and what it says of the rating. [toTheEnd] picks which
/// half, so the two run as suites side by side.
void liveMatrix({required bool toTheEnd}) {
  _setUp();
  for (final (i, (size, scale, locale)) in _live.indexed) {
    if (i.isOdd != toTheEnd) continue;
    testWidgets('live, ${_name(size)}, $locale, text ×$scale, ${toTheEnd ? 'to the game\'s end' : 'a hand'}', (tester) async {
      final faults = await _walkLive(tester, size: size, scale: scale, locale: locale, toTheEnd: toTheEnd);
      expect(faults, isEmpty, reason: faults.join('\n'));
    });
  }
}

/// A phone held upright: the narrow screens, where width runs out.
bool isPhoneUpright(Size size) => size.width < size.height && size.width < 600;
