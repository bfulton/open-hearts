/// The whole game on one screen: the header along the top, the felt in
/// the middle, your score under it, your hand along the bottom
/// (ui/table_layout.dart).
///
/// One screen on purpose. On a phone the game is the app, and anything
/// that pushes the table off-screen — a route, a dialog — costs more
/// than it gives. The menu is the one way off it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'about_page.dart';
import 'avatar.dart';
import 'package:engine/engine.dart';
import 'package:engine/engine.dart' as engine;
import 'game_controller.dart';
import 'identity.dart';
import 'table_model.dart';
import 'theme.dart';
import 'ui/hand_fan.dart';
import 'ui/header.dart';
import 'ui/overlays.dart';
import 'ui/pip.dart';
import 'ui/table_layout.dart';
import 'ui/table_view.dart';
import 'ui/update_pill.dart';

class TablePage extends StatefulWidget {
  const TablePage({super.key, this.seed, this.paced = true, this.target = gameOverScore});

  /// Fixes the shuffle. Tests pass one; the app never does.
  final int? seed;

  /// The score the game runs to, as the front door's options ask for
  /// it (game_options.dart).
  final int target;

  /// False collapses every bot pause to zero, so a widget test can run a
  /// hand out without pumping a clock through 52 plays.
  final bool paced;

  @override
  State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> {
  late final GameController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GameController(seed: widget.seed, paced: widget.paced, target: widget.target)
      ..addListener(_onGameChanged);
    // Your avatar, as chosen in the lobby, on your line here too.
    Identity.avatar().then((a) {
      if (mounted) setState(() => _controller.myAvatar = a);
    });
  }

  void _onGameChanged() => setState(() {});

  List<String> get _seeds => [for (var s = 0; s < seatCount; s++) _controller.iconSeedOf(s)];
  List<Avatar> get _avatars => [for (var s = 0; s < seatCount; s++) _controller.avatarOf(s)];

  @override
  void dispose() {
    _controller
      ..removeListener(_onGameChanged)
      ..dispose();
    super.dispose();
  }

  void _tapCard(engine.Card card) {
    final controller = _controller;
    if (controller.awaitingPass) {
      controller.toggleSelected(card);
      return;
    }
    if (!controller.awaitingPlay) return;
    final refusal = controller.playCard(card);
    if (refusal != null) _say(refusal);
  }

  Future<void> _copyRecord() async {
    await Clipboard.setData(ClipboardData(text: _controller.recordText));
    if (mounted) _say('Record copied');
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        duration: const Duration(milliseconds: 1600),
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
                header: TableHeader(
                  game: game,
                  menu: [
                    MenuAction('Leave the table', icon: Icons.logout, onSelected: () => Navigator.of(context).maybePop()),
                    MenuAction('About', icon: Icons.info_outline, onSelected: () {
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutPage()));
                    }),
                  ],
                ),
                felt: Stack(
                  children: [
                    TableView(controller: _controller),
                    const Positioned(right: 6, bottom: 2, child: UpdatePill()),
                  ],
                ),
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
                  spread: landscape ? 0.8 : 0.64,
                ),
              ),

              if (game.phase == Phase.handOver && _controller.sheetDue)
                HandOverSheet.of(game, names: _controller.names, seeds: _seeds, avatars: _avatars, onNext: _controller.nextHand),
              if (game.phase == Phase.gameOver && _controller.sheetDue)
                GameOverSheet(
                  game: game,
                  names: _controller.names,
                  seeds: _seeds,
                  avatars: _avatars,
                  onNewGame: _controller.newGame,
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
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.controller, required this.onPass, this.note});

  final TableModel controller;
  final VoidCallback onPass;

  /// A line that takes the place of the default note when there is
  /// something more pressing to say — a live table's pause, or a boot
  /// clock.
  final Widget? note;

  @override
  Widget build(BuildContext context) {
    final game = controller.game;

    if (controller.awaitingPass) {
      final chosen = controller.selected.length;
      final ready = chosen == passSize;
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ready
                    ? game.passDirection.label
                    : 'Choose ${passSize - chosen} more to pass',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ready ? Palette.gold : Palette.chromeDim,
                ),
              ),
            ),
            FilledButton(
              onPressed: ready ? onPass : null,
              style: FilledButton.styleFrom(
                backgroundColor: Palette.gold,
                foregroundColor: Felt.dark,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.08),
                disabledForegroundColor: Palette.chromeDim,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11)),
              ),
              child: const Text('Pass',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
    }

    if (this.note != null) return SizedBox(height: 30, child: Center(child: this.note));

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
        text: '${controller.names[from]} passed you',
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
        text: 'Passed to ${controller.names[to]}',
        cards: passed.toList()..sort(),
      );
    }

    // Nothing to say through most of the play: the heart in the header
    // says whether hearts are broken, and the felt says whose turn.
    final note = switch (game.phase) {
      Phase.passing => 'Waiting for the others',
      _ => '',
    };

    return SizedBox(
      height: 30,
      child: Center(
        child: Text(
          note,
          style: const TextStyle(fontSize: 12, color: Palette.chromeDim),
        ),
      ),
    );
  }
}

/// Three cards and a line about them, with an arrow at the seat they
/// came from or went to, so the direction is read off the table rather
/// than out of the sentence.
Widget _cardsLine({required int position, required String text, required List<engine.Card> cards}) {
  return SizedBox(
    height: 30,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(_towards(position), size: 14, color: Palette.chromeDim),
        const SizedBox(width: 3),
        // A long name gives way before the cards do.
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Palette.chromeDim)),
        ),
        for (final card in cards)
          Padding(
            padding: const EdgeInsets.only(left: 9),
            child: Semantics(
              label: card.spoken,
              child: ExcludeSemantics(child: CardChip(card: card, size: 14, onFelt: true)),
            ),
          ),
      ],
    ),
  );
}

/// Which way a seat lies from the player, as an arrow, by its position
/// on screen: left, across, right.
IconData _towards(int position) => switch (position) {
      1 => Icons.arrow_back,
      2 => Icons.arrow_upward,
      _ => Icons.arrow_forward,
    };
