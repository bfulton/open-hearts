/// The player's own seat: the same badge the other three wear, at the
/// near edge of the table — icon, name, the game's total and what this
/// hand has cost so far, and the clock once it is running. It sits
/// hard against the felt's bottom edge, as far under the bottom card
/// as the seat across the felt is over the top one (table_layout.dart).
library;

import 'package:flutter/material.dart';

import '../table_model.dart';
import 'table_view.dart' show SeatBadge;

class ScoreLine extends StatelessWidget {
  const ScoreLine({super.key, required this.controller});

  final TableModel controller;

  @override
  Widget build(BuildContext context) {
    final game = controller.game;
    final seat = controller.mySeat;
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: SeatBadge(
          seat: seat,
          name: controller.names[seat],
          game: game,
          onTurn: game.currentSeat == seat,
          won: game.pendingTrick?.winner == seat,
          clockMs: controller.clockMs(seat),
          iconSeed: controller.iconSeedOf(seat),
          avatar: controller.avatarOf(seat),
          oneLine: true,
          maxWidth: constraints.maxWidth - 12,
        ),
      ),
    );
  }
}
