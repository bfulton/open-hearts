/// The player's own score: the game's total, and what this hand has
/// cost so far — one line just under the felt, where the eye goes
/// between tricks. The other seats' numbers are on their badges.
library;

import 'package:flutter/material.dart';

import '../table_model.dart';
import '../theme.dart';
import 'table_view.dart' show ClockText, clockSeconds;

class ScoreLine extends StatelessWidget {
  const ScoreLine({super.key, required this.controller});

  final TableModel controller;

  static const height = 24.0;

  @override
  Widget build(BuildContext context) {
    final game = controller.game;
    final seat = controller.mySeat;
    final total = game.totals[seat];
    final taken = game.taken[seat];
    final clock = controller.clockMs(seat);
    return Semantics(
      label: 'You: $total in the game, $taken this hand${clock == null ? '' : ', ${clockSeconds(clock)} s on the clock'}',
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                controller.names[seat],
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Palette.gold),
              ),
              const SizedBox(width: 9),
              Text(
                '$total',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                  color: Palette.chrome,
                ),
              ),
              if (taken > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '+$taken',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Palette.danger.withValues(alpha: 0.9)),
                ),
              ],
              // Your own clock, once you are spending it.
              if (clock != null) ...[
                const SizedBox(width: 12),
                ClockText(ms: clock),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
