/// The whole game on one screen: the header along the top, the felt in
/// the middle, your score under it, your hand along the bottom
/// (ui/table_layout.dart).
///
/// One screen on purpose. On a phone the game is the app, and anything
/// that pushes the table off-screen — a route, a dialog — costs more
/// than it gives. The menu is the one way off it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:flutter/material.dart' hide Card;

import 'entitlement.dart';
import 'feedback_page.dart';
import 'game_controller.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/copy.dart';
import 'pages.dart';
import 'table_model.dart';
import 'theme.dart';
import 'tutorial.dart';
import 'ui/coach_note.dart';
import 'ui/gone.dart';
import 'ui/hand_fan.dart';
import 'ui/header.dart';
import 'ui/overlays.dart';
import 'ui/pip.dart';
import 'ui/reading_time.dart';
import 'ui/table_layout.dart';
import 'ui/table_view.dart';
import 'ui/update_pill.dart';

/// A game alone, as `/solo` is opened with it (router.dart, soloPath):
/// what the address cannot carry.
class SoloGame {
  const SoloGame({this.target = gameOverScore, this.seed, this.paced = true, this.learning = false});

  final int target;
  final int? seed;
  final bool paced;

  /// The hand a new player is taught on, rather than a game
  /// (tutorial.dart).
  final bool learning;
}

class TablePage extends StatefulWidget {
  const TablePage({super.key, this.seed, this.paced = true, this.target = gameOverScore, this.learning = false});

  /// Fixes the shuffle: a test's, or a browser suite's under `?e2e&seed=`
  /// (home_page.dart); in play, never.
  final int? seed;

  /// The score the game runs to, as the front door's options ask for
  /// it (game_options.dart).
  final int target;

  /// False collapses every bot pause to zero, so a widget test can run a
  /// hand out without pumping a clock through 52 plays.
  final bool paced;

  /// The hand a new player is taught on (tutorial.dart): the same deal
  /// every time, a note at each thing it comes to, and the score sheet
  /// at its end the way home.
  final bool learning;

  @override
  State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> {
  late final GameController _controller;

  /// The notes, where this is the hand a new player is taught on.
  Tutorial? _tutorial;

  @override
  void initState() {
    super.initState();
    _controller = GameController(
      seed: widget.learning ? Tutorial.seed : widget.seed,
      paced: widget.paced,
      target: widget.target,
      hold: widget.learning ? () => _tutorial!.ready() : null,
    )..addListener(_onGameChanged);
    if (widget.learning) {
      _tutorial = Tutorial(_controller)..addListener(_onGameChanged);
      // Opened is enough: the front door offers it once (tutorial.dart).
      unawaited(Learning.opened());
    }
    // Your avatar, as chosen in the lobby, on your line here too.
    Identity.avatar().then((a) {
      if (mounted) setState(() => _controller.myAvatar = a);
    });
    // And your initials on your colour, as the front door's icon has
    // them (home_page.dart), where you chose no icon.
    () async {
      final name = await Identity.name() ?? '';
      final seed = Entitlement.current.licence?.account ?? (await Identity.signer()).publicKey;
      if (mounted) {
        setState(() => _controller
          ..myName = name
          ..mySeed = seed);
      }
    }();
  }

  /// The controller names the player and turns down a card in the
  /// app's language, which is known once the page is in the tree.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.words = context.l10n;
  }

  void _onGameChanged() => setState(() {});


  @override
  void dispose() {
    _tutorial
      ?..removeListener(_onGameChanged)
      ..dispose();
    _controller
      ..removeListener(_onGameChanged)
      ..dispose();
    super.dispose();
  }

  void _tapCard(Card card) {
    // A note being read holds the player's cards as it holds the bots'.
    if (_tutorial?.holds ?? false) return;
    final controller = _controller;
    if (controller.awaitingPass) {
      controller.toggleSelected(card);
      return;
    }
    if (!controller.awaitingPlay) return;
    final refusal = controller.playCard(card);
    if (refusal != null) _say(refusal);
  }

  /// The note up now, where this is the hand a new player is taught on:
  /// any but the score's, which the sheet says. The felt gives it room
  /// (ui/table_layout.dart, note), so it is over nothing on the table.
  Widget? _coachNote() {
    final tutorial = _tutorial;
    final text = tutorial?.say(context.l10n);
    if (tutorial == null || text == null || tutorial.showing == Lesson.score) return null;
    return CoachNote(text: text, next: tutorial.holds ? context.l10n.tutorialNext : null, onNext: tutorial.next);
  }

  Future<void> _copyRecord() async {
    await copyText(_controller.recordText);
    if (mounted) _say(context.l10n.recordCopied);
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        duration: readingTime(message),
        width: 260,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final game = _controller.game;
    final hand = _controller.handShown;
    final legal = _controller.legalNow;
    final passing = _controller.awaitingPass;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Stack(
            children: [
              TableLayout(
                // Where there is room beside the table, what a phone
                // has to hide goes in it (ui/gone.dart).
                rail: (width) => Gone(played: _controller.playedThisHand, width: width),
                header: TableHeader(
                  game: game,
                  menu: [
                    MenuAction(context.l10n.leaveTheTable, icon: Icons.logout, onSelected: () => Navigator.of(context).maybePop(), danger: true),
                    MenuAction(context.l10n.tellUsWhatsBroken,
                        icon: Icons.feedback_outlined, onSelected: () => showFeedback(context, record: _controller.recordText)),
                    MenuAction(context.l10n.about, icon: Icons.info_outline, onSelected: () {
                      openPage<void>(context, AppPage.about);
                    }),
                  ],
                ),
                felt: Stack(
                  children: [
                    TableView(controller: _controller),
                    const Positioned(right: 6, bottom: 2, child: UpdatePill()),
                  ],
                ),
                note: _coachNote(),
                action: ActionBar(
                  controller: _controller,
                  onPass: _controller.confirmPass,
                ),
                hand: (landscape) => HandFan(
                  hand: hand,
                  onTap: _tapCard,
                  playable: passing
                      ? hand.toSet()
                      : legal,
                  selected: _controller.selected,
                  dimUnplayable: _controller.awaitingPlay,
                  forced: legal.length == 1 ? legal.first : null,
                  justReceived: game.tricksPlayed == 0
                      ? game.receivedBy(_controller.mySeat).toSet()
                      : const {},
                  // Where a card the player gives up goes, and where
                  // the ones they are given come from: the side of the
                  // screen the other end of the pass sits on. Through
                  // the play a card that leaves has been played, and
                  // rises to the table instead (ui/hand_fan.dart).
                  passTo: game.phase == Phase.passing ? passesTo(_controller) : null,
                  receivedFrom: passesFrom(_controller),
                  spread: HandFan.spreadFor(landscape: landscape),
                ),
              ),

              if (game.phase == Phase.handOver && _controller.sheetDue)
                _tutorial == null
                    ? HandOverSheet.of(game, seats: _controller.looks, onNext: _controller.nextHand)
                    : HandOverSheet.of(game,
                        seats: _controller.looks,
                        // The one hand, and home after it.
                        onNext: () => Navigator.of(context).maybePop(),
                        action: context.l10n.done,
                        note: _tutorial!.say(context.l10n)),
              if (game.phase == Phase.gameOver && _controller.sheetDue)
                GameOverSheet(
                  game: game,
                  seats: _controller.looks,
                  onNewGame: _controller.newGame,
                  onHome: () => Navigator.of(context).maybePop(),
                  onCopyRecord: _copyRecord,
                ),

            ],
          ),
        ),
      ),
    );
  }
}

/// The line between the felt and your hand: what the game wants from you,
/// and the Pass button when it wants three cards.
///
/// One height whatever it holds, so the table above never shifts under
/// it: the height of the pass, its tallest state, at the width the line
/// has and the reader's own text size. Everything on it is reading text
/// and is drawn at the size the reader asked for (WCAG 1.4.4): the
/// prompt wraps to a second line beside the button where it needs one,
/// and where even two will not hold it, says it shorter (see
/// [_PassFit]); a note takes two lines and, past that, an ellipsis.
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.controller, required this.onPass, this.note});

  final TableModel controller;
  final VoidCallback onPass;

  /// A line that takes the place of the default note when there is
  /// something more pressing to say — a live table's pause, or a boot
  /// clock.
  final Widget? note;

  static const _padding = EdgeInsets.fromLTRB(14, 4, 14, 2);
  static const _prompt = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
  static const _note = TextStyle(fontSize: 12, color: Palette.chromeDim);
  static const _buttonPadding = EdgeInsets.symmetric(horizontal: 22, vertical: 9);
  static const _buttonLabel = TextStyle(fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = _PassFit.of(context, width: constraints.maxWidth, direction: controller.game.passDirection);
        return SizedBox(height: fit.height, child: _state(context, fit));
      },
    );
  }

  Widget _state(BuildContext context, _PassFit fit) {
    final l10n = context.l10n;
    final game = controller.game;

    if (controller.awaitingPass) {
      final chosen = controller.selected.length;
      final ready = chosen == passSize;
      return Padding(
        padding: _padding,
        child: Row(
          children: [
            Expanded(
              child: Text(
                ready ? l10n.pass(game.passDirection) : fit.prompt(l10n, passSize - chosen),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _prompt.copyWith(color: ready ? Palette.gold : Palette.chromeDim),
              ),
            ),
            FilledButton(
              onPressed: ready ? onPass : null,
              style: FilledButton.styleFrom(
                backgroundColor: Palette.gold,
                foregroundColor: Felt.dark,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.08),
                disabledForegroundColor: Palette.chromeDim,
                padding: _buttonPadding,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11)),
              ),
              child: Text(l10n.passButton, style: _buttonLabel),
            ),
          ],
        ),
      );
    }

    final line = _playLine(context);
    if (!controller.autoOffered) return line;
    // The Auto switch, at the end of the line nearest the hand's last
    // card — the one it plays. The line gives up the width it takes, so
    // the two never overlap: what was centred in the whole row is
    // centred in what is left of it.
    return Row(
      children: [
        Expanded(child: line),
        AutoSwitch(on: controller.autoPlay, onChanged: controller.setAutoPlay),
      ],
    );
  }

  /// The line through the play: the table's note, what was passed, or
  /// nothing.
  Widget _playLine(BuildContext context) {
    final l10n = context.l10n;
    final game = controller.game;

    // Two lines at most, in whatever room the switch leaves it: the
    // line keeps the height for two of them (_PassFit).
    if (this.note != null) {
      return Center(
        child: DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          child: this.note!,
        ),
      );
    }

    final received = game.receivedBy(controller.mySeat);

    // Through the whole first trick, not just the lead: the bots play
    // into the trick before your turn comes round, and what you were
    // handed is the thing you most want in front of you while you
    // decide.
    if (game.phase == Phase.playing &&
        game.tricksPlayed == 0 &&
        received.isNotEmpty) {
      final from = game.passerTo(controller.mySeat);
      return _cardsLine(
        position: controller.positionOf(from),
        said: l10n.passedYou,
        name: controller.names[from],
        l10n: l10n,
        cards: received,
      );
    }

    // While the others choose: what you passed, and to whom — out of
    // the hand, where it would only read as still yours.
    final passed = controller.passed;
    if (game.phase == Phase.passing && passed.isNotEmpty) {
      final to = (controller.mySeat + game.passDirection.seatOffset) % seatCount;
      return _cardsLine(
        position: controller.positionOf(to),
        said: l10n.passedTo,
        name: controller.names[to],
        l10n: l10n,
        cards: passed.toList()..sort(),
      );
    }

    // Nothing to say through most of the play: the heart in the header
    // says whether hearts are broken, and the felt says whose turn.
    final note = switch (game.phase) {
      Phase.passing => l10n.waitingForOthers,
      _ => '',
    };

    return Center(
      child: Text(
        note,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: _note,
      ),
    );
  }
}

/// The pass as the line will say it, worked out before it is laid out:
/// which form of the prompt fits beside the Pass button at this width
/// and this reader's text size, and so how tall the line is.
///
/// The prompt is said in full where two lines of it fit. Where they do
/// not — large type on a narrow phone — it says only how many more to
/// choose, and leaves "to pass" to the button beside it that says so;
/// the reader keeps the size they asked for, and loses no more than
/// the button already tells them. Measured rather than guessed, in the
/// type the line is drawn in, so the line holds its height through the
/// pass and the play alike.
class _PassFit {
  const _PassFit({required this.full, required this.height});

  factory _PassFit.of(BuildContext context, {required double width, required PassDirection direction}) {
    final l10n = context.l10n;
    final scaler = MediaQuery.textScalerOf(context);
    final ambient = DefaultTextStyle.of(context).style;
    TextPainter laid(String text, TextStyle style, double room) => TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 2,
        )..layout(maxWidth: room);

    // The button, as FilledButton draws it: its label in the theme's
    // button type, inside its padding, and never under its least
    // size or a finger's.
    final label = laid(l10n.passButton, Theme.of(context).textTheme.labelLarge!.merge(ActionBar._buttonLabel), double.infinity);
    final button = Size(
      (label.width + ActionBar._buttonPadding.horizontal).clamp(64.0, double.infinity),
      (label.height + ActionBar._buttonPadding.vertical).clamp(kMinInteractiveDimension, double.infinity),
    );
    final room = (width - ActionBar._padding.horizontal - button.width).clamp(0.0, double.infinity);
    final style = ambient.merge(ActionBar._prompt);
    bool fits(String text) => !laid(text, style, room).didExceedMaxLines;
    final full = [for (var n = passSize; n > 0; n--) l10n.choosePass(n)].every(fits);
    final said = [
      for (var n = passSize; n > 0; n--) full ? l10n.choosePass(n) : l10n.choosePassShort(n),
      l10n.pass(direction),
    ];
    final words = said.map((s) => laid(s, style, room).height).fold(0.0, math.max);
    // And through the play, two lines of a note: what was passed, or at
    // a live table what it is waiting for, which wraps rather than cut.
    final notes = laid('M\nM', ambient.merge(ActionBar._note), double.infinity).height;
    return _PassFit(full: full, height: math.max(ActionBar._padding.vertical + math.max(words, button.height), notes));
  }

  /// Whether the prompt is said in full.
  final bool full;

  /// The line's height: the tallest of the prompt beside the button and
  /// two lines of a note. The table keeps a row at least this tall
  /// whatever the line holds (ui/table_layout.dart).
  final double height;

  String prompt(AppLocalizations l10n, int count) => full ? l10n.choosePass(count) : l10n.choosePassShort(count);
}

/// Three cards and a line about them, with an arrow at the seat they
/// came from or went to, so the direction is read off the table rather
/// than out of the sentence.
Widget _cardsLine(
    {required int position,
    required String Function(String name) said,
    required String name,
    required List<Card> cards,
    required AppLocalizations l10n}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(_towards(position), size: 14, color: Palette.chromeDim),
      const SizedBox(width: 3),
      // The words wrap to a second line before a long name gives way,
      // and a long name gives way before the cards do; a screen reader
      // hears the whole of it.
      Flexible(
        child: LayoutBuilder(
          builder: (context, room) {
            final whole = said(name);
            final shown = nameGivesWay(context, said: said, name: name, style: ActionBar._note, width: room.maxWidth, lines: 2);
            final text = Text(shown, maxLines: 2, overflow: TextOverflow.ellipsis, style: ActionBar._note);
            return shown == whole ? text : Semantics(label: whole, child: ExcludeSemantics(child: text));
          },
        ),
      ),
      for (final card in cards)
        Padding(
          padding: const EdgeInsets.only(left: 9),
          child: Semantics(
            label: l10n.card(card),
            child: ExcludeSemantics(child: CardChip(card: card, size: 14, onFelt: true)),
          ),
        ),
    ],
  );
}

/// Which way a seat lies from the player, as an arrow, by its position
/// on screen: left, across, right.
IconData _towards(int position) => switch (position) {
      1 => Icons.arrow_back,
      2 => Icons.arrow_upward,
      _ => Icons.arrow_forward,
    };

/// The switch that has the table play the rest of the hand: shown
/// once nothing the player holds can change how it comes out (engine,
/// autopilot.dart), and said aloud as it appears, since it turns up
/// unasked in the middle of a hand.
///
/// "Auto" on the felt, and the whole of what it does to a screen
/// reader: one short word is what fits beside a hand in every
/// language, and a switch is read out with its label, not looked at.
class AutoSwitch extends StatelessWidget {
  const AutoSwitch({super.key, required this.on, required this.onChanged});

  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Announced(
      message: l10n.autoOffered,
      child: MergeSemantics(
        child: Semantics(
          label: l10n.autoPlayLabel,
          child: GestureDetector(
            // The word is part of the switch: a tap on either turns it.
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(!on),
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      l10n.autoSwitch,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        // Gold while it is doing something for you.
                        color: on ? Palette.gold : Palette.chromeDim,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Switch(
                    value: on,
                    onChanged: onChanged,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    activeThumbColor: Felt.dark,
                    activeTrackColor: Palette.gold,
                    inactiveThumbColor: Palette.chromeDim,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                    trackOutlineColor: WidgetStatePropertyAll(Palette.chromeDim.withValues(alpha: 0.5)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
