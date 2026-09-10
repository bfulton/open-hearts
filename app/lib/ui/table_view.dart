/// The felt: opponents around the edge, the trick in the middle.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';
import 'package:engine/engine.dart' as engine;
import '../table_model.dart';
import '../theme.dart';
import 'card_view.dart';
import 'pip.dart';

/// Where each seat's badge sits: pinned to the rail, well clear of the
/// trick. Seat 0 is the player at the bottom and has no badge — the
/// scoreboard and the hand say everything about them. Play runs 0-1-2-3,
/// which reads clockwise once the seats are laid out this way.
const _badgeAt = <int, Alignment>{
  1: Alignment(-1, -0.18),
  2: Alignment(0, -1),
  3: Alignment(1, -0.18),
};

/// Which way each seat's played card sits from the middle of the trick,
/// in units of the trick card's own size.
const _trickOffset = <int, Offset>{
  0: Offset(0, 0.78),
  1: Offset(-0.86, 0),
  2: Offset(0, -0.78),
  3: Offset(0.86, 0),
};

class TableView extends StatelessWidget {
  const TableView({super.key, required this.controller});

  final TableModel controller;

  @override
  Widget build(BuildContext context) {
    final game = controller.game;
    final pending = game.pendingTrick;

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        // The trick has to fit four cards in a diamond AND leave the
        // badges their rail, so it is sized from whichever dimension
        // runs out first rather than from the width alone.
        final cardWidth = [
          box.width * 0.21,
          box.height * 0.155,
          76.0,
        ].reduce((a, b) => a < b ? a : b).clamp(34.0, 76.0);
        final cardHeight = cardHeightFor(cardWidth);
        final trickBox = Size(cardWidth * 2.9, cardHeight * 2.7);

        return Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Stack(
                children: [
                  for (var position = 1; position < seatCount; position++)
                    Align(
                      alignment: _badgeAt[position]!,
                      child: _SeatBadge(
                        seat: controller.seatAt(position),
                        name: controller.names[controller.seatAt(position)],
                        game: game,
                        onTurn: game.currentSeat == controller.seatAt(position),
                        won: pending?.winner == controller.seatAt(position),
                      ),
                    ),
                ],
              ),
            ),

            // The trick, as one centred block. Slots hold their place so
            // arriving cards never shove the layout around.
            Align(
              alignment: const Alignment(0, -0.06),
              child: SizedBox.fromSize(
                size: trickBox,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    for (var position = 0; position < seatCount; position++)
                      Transform.translate(
                        offset: Offset(
                          _trickOffset[position]!.dx * cardWidth * 1.15,
                          _trickOffset[position]!.dy * cardHeight * 1.02,
                        ),
                        child: _TrickSlot(
                          card: _cardFrom(game, controller.seatAt(position)),
                          width: cardWidth,
                          winning: pending != null && pending.winner == controller.seatAt(position),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Under the trick, never across it: centred, the pill lands
            // exactly where the west and east cards meet.
            Align(
              alignment: const Alignment(0, 0.88),
              child: pending != null
                  ? _TrickResult(
                      you: pending.winner == controller.mySeat,
                      name: controller.names[pending.winner],
                      points: pointsIn(pending.plays.map((p) => p.card)),
                    )
                  : game.phase == Phase.playing
                      ? _TurnHint(game: game, mySeat: controller.mySeat)
                      : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }

  engine.Card? _cardFrom(HeartsGame game, int seat) {
    for (final p in game.trick) {
      if (p.seat == seat) return p.card;
    }
    return null;
  }
}

class _TrickSlot extends StatelessWidget {
  const _TrickSlot({required this.card, required this.width, required this.winning});

  final engine.Card? card;
  final double width;
  final bool winning;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 190),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween(begin: 0.82, end: 1.0).animate(animation), child: child),
      ),
      child: card == null
          ? CardGhost(key: const ValueKey('empty'), width: width)
          : CardView(
              key: ValueKey(card!.code),
              card: card!,
              width: width,
              highlighted: winning,
            ),
    );
  }
}

/// An opponent: who they are, how many cards they hold, what they have
/// taken this hand.
class _SeatBadge extends StatelessWidget {
  const _SeatBadge({
    required this.seat,
    required this.name,
    required this.game,
    required this.onTurn,
    required this.won,
  });

  final int seat;
  final String name;
  final HeartsGame game;
  final bool onTurn;
  final bool won;

  @override
  Widget build(BuildContext context) {
    final cards = game.handOf(seat).length;
    final taken = game.taken[seat];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: onTurn ? 0.42 : 0.24),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: onTurn || won ? Palette.gold : Colors.white.withValues(alpha: 0.10),
          width: onTurn || won ? 1.6 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: onTurn ? Palette.gold : Palette.chrome,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.style, size: 11, color: Palette.chromeDim),
              const SizedBox(width: 3),
              Text('$cards', style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim)),
              if (taken > 0) ...[
                const SizedBox(width: 7),
                Pip(
                    suit: engine.Suit.hearts,
                    size: 10,
                    color: Palette.danger.withValues(alpha: 0.9)),
                const SizedBox(width: 3),
                Text('$taken',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Palette.danger.withValues(alpha: 0.95))),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TrickResult extends StatelessWidget {
  const _TrickResult({required this.you, required this.name, required this.points});

  final bool you;
  final String name;
  final int points;

  @override
  Widget build(BuildContext context) {
    final who = you ? 'You take it' : '$name takes it';
    return _Pill(
      text: points == 0 ? who : '$who  ·  $points',
      tone: points == 0 ? Palette.gold : Palette.danger,
    );
  }
}

class _TurnHint extends StatelessWidget {
  const _TurnHint({required this.game, required this.mySeat});

  final HeartsGame game;
  final int mySeat;

  @override
  Widget build(BuildContext context) {
    final seat = game.currentSeat;
    if (seat == null) return const SizedBox.shrink();
    if (seat == mySeat) {
      return _Pill(
        text: game.trick.isEmpty ? 'Your lead' : 'Your turn',
        tone: Palette.gold,
      );
    }
    return const SizedBox.shrink();
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.tone});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: tone,
        ),
      ),
    );
  }
}
