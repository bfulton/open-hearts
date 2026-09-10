/// The whole game on one screen: scores on top, felt in the middle, your
/// hand along the bottom.
///
/// One screen on purpose. On a phone the game is the app, and anything
/// that pushes the table off-screen — a menu, a route, a dialog — costs
/// more than it gives.
library;

import 'package:flutter/material.dart';

import 'build_info.dart';
import 'package:engine/engine.dart';
import 'package:engine/engine.dart' as engine;
import 'game_controller.dart';
import 'theme.dart';
import 'ui/hand_fan.dart';
import 'ui/overlays.dart';
import 'ui/pip.dart';
import 'ui/scoreboard.dart';
import 'ui/table_view.dart';

class TablePage extends StatefulWidget {
  const TablePage({super.key, this.seed, this.paced = true});

  /// Fixes the shuffle. Tests pass one; the app never does.
  final int? seed;

  /// False collapses every bot pause to zero, so a widget test can run a
  /// hand out without pumping a clock through 52 plays.
  final bool paced;

  @override
  State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> with WidgetsBindingObserver {
  late final GameController _controller;

  /// A newer deploy's tag, once one is seen. Drives the update pill.
  String? _newBuild;

  @override
  void initState() {
    super.initState();
    _controller = GameController(seed: widget.seed, paced: widget.paced)
      ..addListener(_onGameChanged);
    WidgetsBinding.instance.addObserver(this);
    if (updateCheckEnabled) _checkForUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No polling: a foreground return is the installed-app equivalent of
    // a page load, and that is the only moment the answer can matter.
    if (state == AppLifecycleState.resumed && updateCheckEnabled) {
      _checkForUpdate();
    }
  }

  Future<void> _checkForUpdate() async {
    final deployed = await publishedBuild();
    if (!mounted) return;
    setState(() {
      _newBuild = (deployed != null && deployed != buildTag) ? deployed : null;
    });
  }

  void _onGameChanged() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    final hand = game.handOf(humanSeat);
    final legal = _controller.legalNow;
    final passing = _controller.awaitingPass;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Scoreboard(game: game, names: _controller.names),
                  Expanded(
                    child: Stack(
                      children: [
                        TableView(controller: _controller),
                        Positioned(
                          right: 6,
                          bottom: 2,
                          child: _BuildStamp(
                              newBuild: _newBuild, onReload: _reload),
                        ),
                      ],
                    ),
                  ),
                  _ActionBar(
                    controller: _controller,
                    onPass: _controller.confirmPass,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                    child: SizedBox(
                      height: 128,
                      child: HandFan(
                        hand: hand,
                        onTap: _tapCard,
                        playable: passing
                            ? hand.toSet()
                            : legal,
                        selected: _controller.selected,
                        dimUnplayable: _controller.awaitingPlay,
                        forced: legal.length == 1 ? legal.first : null,
                        justReceived: game.tricksPlayed == 0
                            ? game.receivedBy(humanSeat).toSet()
                            : const {},
                      ),
                    ),
                  ),
                ],
              ),

              if (game.phase == Phase.handOver)
                HandOverSheet(game: game, names: _controller.names, onNext: _controller.nextHand),
              if (game.phase == Phase.gameOver)
                GameOverSheet(game: game, names: _controller.names, onNewGame: _controller.newGame),

            ],
          ),
        ),
      ),
    );
  }

  void _reload() => reloadPage();
}

/// The line between the felt and your hand: what the game wants from you,
/// and the Pass button when it wants three cards.
class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.controller, required this.onPass});

  final GameController controller;
  final VoidCallback onPass;

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

    final received = game.receivedBy(humanSeat);

    // Through the whole first trick, not just the lead: the bots play
    // into the trick before your turn comes round, and what you were
    // handed is the thing you most want in front of you while you
    // decide.
    if (game.phase == Phase.playing &&
        game.tricksPlayed == 0 &&
        received.isNotEmpty) {
      final from = game.passerTo(humanSeat);
      return SizedBox(
        height: 30,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Points at the seat the cards came from, so the direction
            // is read off the table rather than out of the sentence.
            Icon(_towards(from), size: 14, color: Palette.chromeDim),
            const SizedBox(width: 3),
            Text('${controller.names[from]} passed you',
                style: const TextStyle(fontSize: 12, color: Palette.chromeDim)),
            for (final card in received)
              Padding(
                padding: const EdgeInsets.only(left: 9),
                child: CardChip(card: card, size: 14, onFelt: true),
              ),
          ],
        ),
      );
    }

    final note = switch (game.phase) {
      Phase.passing => 'Waiting for the others',
      Phase.playing when controller.awaitingPlay => game.heartsBroken
          ? 'Hearts are broken'
          : 'Hearts not broken',
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

/// Which way a seat lies from the player, as an arrow. Seats are drawn
/// west-left, north-top, east-right, so the mapping is literal.
IconData _towards(int seat) => switch (seat) {
      1 => Icons.arrow_back,
      2 => Icons.arrow_upward,
      _ => Icons.arrow_forward,
    };

/// The running build, and the tap target that picks up a newer one.
///
/// The dev loop publishes on every commit; without this the honest
/// answer to "is this the new build?" is a hard refresh and a guess.
class _BuildStamp extends StatelessWidget {
  const _BuildStamp({required this.newBuild, required this.onReload});

  final String? newBuild;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    if (newBuild != null) {
      return GestureDetector(
        onTap: onReload,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: Palette.gold,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 10),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.refresh, size: 13, color: Felt.dark),
              const SizedBox(width: 5),
              Text('$newBuild is up',
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Felt.dark)),
            ],
          ),
        ),
      );
    }
    return Text(
      buildTag,
      style: TextStyle(
        fontSize: 9.5,
        color: Palette.chrome.withValues(alpha: 0.22),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
