/// The scoreboard: everyone's total, who is taking damage this hand, and
/// which way the pass is going — a strip along the top when height is
/// spare, a rail down the side when it is not (table_layout.dart).
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';

import '../theme.dart';

class Scoreboard extends StatelessWidget {
  const Scoreboard({super.key, required this.game, required this.names, this.mySeat = humanSeat, this.axis = Axis.horizontal});

  final HeartsGame game;

  /// Seat names, seat order.
  final List<String> names;

  /// The player's seat, shown first.
  final int mySeat;

  /// Along the top ([Axis.horizontal]) or down the side ([Axis.vertical]).
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final rail = axis == Axis.vertical;
    return Container(
      padding: rail ? const EdgeInsets.fromLTRB(10, 10, 10, 8) : const EdgeInsets.fromLTRB(10, 6, 10, 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        border: Border(
          bottom: rail ? BorderSide.none : BorderSide(color: Colors.white.withValues(alpha: 0.07)),
          right: rail ? BorderSide(color: Colors.white.withValues(alpha: 0.07)) : BorderSide.none,
        ),
      ),
      child: rail ? _rail() : _strip(),
    );
  }

  Widget _strip() {
    return Column(
      children: [
        Row(
          children: [
            for (var p = 0; p < seatCount; p++)
              Expanded(
                child: _SeatScore(
                  game: game,
                  seat: (p + mySeat) % seatCount,
                  name: names[(p + mySeat) % seatCount],
                  isYou: p == 0,
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          'Hand ${game.handNumber + 1}  ·  ${game.passDirection.label}'
          '  ·  to $gameOverScore',
          style: _handStyle,
        ),
      ],
    );
  }

  /// The same four, stacked, the hand's line at the foot: a long name
  /// scales to the rail as it does to a quarter of the strip.
  Widget _rail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var p = 0; p < seatCount; p++)
          Padding(
            padding: EdgeInsets.only(bottom: p == seatCount - 1 ? 0 : 9),
            child: _SeatScore(
              game: game,
              seat: (p + mySeat) % seatCount,
              name: names[(p + mySeat) % seatCount],
              isYou: p == 0,
              inRail: true,
            ),
          ),
        const Spacer(),
        Text('Hand ${game.handNumber + 1}', textAlign: TextAlign.center, style: _handStyle),
        Text(game.passDirection.label, textAlign: TextAlign.center, style: _handStyle),
        Text('to $gameOverScore', textAlign: TextAlign.center, style: _handStyle),
      ],
    );
  }

  static const _handStyle = TextStyle(
    fontSize: 10.5,
    color: Palette.chromeDim,
    letterSpacing: 0.3,
  );
}

class _SeatScore extends StatelessWidget {
  const _SeatScore({
    required this.game,
    required this.seat,
    required this.name,
    required this.isYou,
    this.inRail = false,
  });

  final HeartsGame game;
  final int seat;
  final String name;
  final bool isYou;

  /// In the rail the name and the total share a line, the name to the
  /// left, the numbers to the right.
  final bool inRail;

  @override
  Widget build(BuildContext context) {
    final taken = game.taken[seat];
    // A long name — Mumtaz Mahal, Mark Antony — scales down to its
    // quarter of the strip, or the rail's width, rather than spilling.
    final nameText = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: inRail ? Alignment.centerLeft : Alignment.center,
      child: Text(
        name,
        maxLines: 1,
        style: TextStyle(
          fontSize: 11,
          fontWeight: isYou ? FontWeight.w700 : FontWeight.w500,
          color: isYou ? Palette.gold : Palette.chromeDim,
        ),
      ),
    );
    // A three-digit total beside a two-digit hand is the widest this
    // gets, and on a narrow phone it is a hair too wide for a quarter
    // of the strip: scale the pair down rather than clip it.
    final numbers = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${game.totals[seat]}',
            style: TextStyle(
              fontSize: inRail ? 17 : 19,
              height: 1.1,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: isYou ? Palette.chrome : Palette.chrome.withValues(alpha: 0.82),
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
    );
    if (inRail) {
      return Row(
        children: [
          Expanded(child: nameText),
          const SizedBox(width: 6),
          numbers,
        ],
      );
    }
    return Column(
      children: [
        nameText,
        const SizedBox(height: 1),
        numbers,
      ],
    );
  }
}
