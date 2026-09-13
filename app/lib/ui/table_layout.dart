/// The table's composition, chosen from the space it is given
/// (docs/05-form-factors.md).
///
/// Portrait and landscape have opposite scarcities. In portrait width
/// runs out: thirteen cards fan across 390 points, so the score strip
/// can sit along the top. In landscape there is width to spare and only
/// 390 points of height, and the strip along the top would take a third
/// of it before the trick got any — so the strip becomes a rail down
/// the side, the trick gets its height back, and the hand keeps the
/// bottom edge near the thumbs, shorter, with more of each card showing.
/// One layout with the scoreboard on a different edge; everything under
/// it is shared.
///
/// Chosen from the constraints, never from the device: a phone turning,
/// a window dragged narrower and a foldable opening are one event, and
/// the game's state lives above this widget, so the turn keeps the hand.
library;

import 'package:flutter/material.dart';

class TableLayout extends StatelessWidget {
  const TableLayout({
    super.key,
    required this.scoreboard,
    required this.felt,
    required this.action,
    required this.hand,
    this.below,
  });

  /// The scoreboard for the edge it gets: a strip ([Axis.horizontal])
  /// along the top, or a rail ([Axis.vertical]) down the left.
  final Widget Function(Axis axis) scoreboard;

  /// The felt: the trick, the seats, and whatever floats over them.
  final Widget felt;

  /// The line between the felt and the hand.
  final Widget action;

  /// The hand, told whether width is spare — a landscape fan shows more
  /// of each card.
  final Widget Function(bool landscape) hand;

  /// A line between the felt and the action, when a page has one.
  final Widget? below;

  /// Wider than tall by a margin: a near-square window is laid out as
  /// portrait, where the fan is the part that needs the width.
  static bool isLandscape(BoxConstraints constraints) => constraints.maxWidth > constraints.maxHeight * 1.2;

  /// The hand's height in each composition: the fan sizes its cards from
  /// it, so the landscape hand is shorter cards shown wider.
  static const portraitHandHeight = 128.0;
  static const landscapeHandHeight = 100.0;

  /// The rail's width: four names and totals, and the hand's line.
  static const railWidth = 118.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape = isLandscape(constraints);
        final column = Column(
          children: [
            if (!landscape) scoreboard(Axis.horizontal),
            Expanded(child: felt),
            ?below,
            action,
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: SizedBox(
                height: landscape ? landscapeHandHeight : portraitHandHeight,
                child: hand(landscape),
              ),
            ),
          ],
        );
        if (!landscape) return column;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: railWidth, child: scoreboard(Axis.vertical)),
            Expanded(child: column),
          ],
        );
      },
    );
  }
}
