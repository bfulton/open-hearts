/// The strip along the top: everyone's total, who is taking damage this
/// hand, and which way the pass is going.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';

import '../theme.dart';

class Scoreboard extends StatelessWidget {
  const Scoreboard({super.key, required this.game, required this.names});

  final HeartsGame game;

  /// Seat names, seat order.
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (var seat = 0; seat < seatCount; seat++)
                Expanded(
                  child: _SeatScore(game: game, seat: seat, name: names[seat]),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Hand ${game.handNumber + 1}  ·  ${game.passDirection.label}'
            '  ·  to $gameOverScore',
            style: const TextStyle(
              fontSize: 10.5,
              color: Palette.chromeDim,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatScore extends StatelessWidget {
  const _SeatScore({
    required this.game,
    required this.seat,
    required this.name,
  });

  final HeartsGame game;
  final int seat;
  final String name;

  @override
  Widget build(BuildContext context) {
    final isYou = seat == humanSeat;
    final taken = game.taken[seat];
    return Column(
      children: [
        Text(
          name,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isYou ? FontWeight.w700 : FontWeight.w500,
            color: isYou ? Palette.gold : Palette.chromeDim,
          ),
        ),
        const SizedBox(height: 1),
        // A three-digit total beside a two-digit hand is the widest this
        // gets, and on a narrow phone it is a hair too wide for a quarter
        // of the strip: scale the pair down rather than clip it.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${game.totals[seat]}',
                style: TextStyle(
                  fontSize: 19,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: isYou
                      ? Palette.chrome
                      : Palette.chrome.withValues(alpha: 0.82),
                ),
              ),
              if (taken > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: Text(
                    '+$taken',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Palette.danger.withValues(alpha: 0.9),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
