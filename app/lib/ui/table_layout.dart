/// The table's composition, chosen from the space it is given
/// (docs/05-form-factors.md).
///
/// Top to bottom: the header (menu, where the game stands, the heart),
/// the felt, the action line, the hand. The player's own score is not a
/// row here: they are the fourth seat on the felt, a badge the same gap
/// from the cards as the other three (ui/table_view.dart). Nor is what
/// the table says: that floats in the room the felt keeps under the
/// near seat, so what sits against the hand is the line about the hand. The
/// same order in portrait and landscape; what changes with the shape
/// is the hand. In portrait width runs out — thirteen cards fan across
/// 390 points — so the fan overlaps hard and the cards take the height
/// they need. In landscape there is width to spare and only 390 points
/// of height, so the hand is shorter and its fan steps wider, showing
/// more of each card, and the felt keeps what height is left.
///
/// Chosen from the constraints, never from the device: a phone turning,
/// a window dragged narrower and a foldable opening are one event, and
/// the game's state lives above this widget, so the turn keeps the hand.
library;

import 'package:flutter/material.dart';

class TableLayout extends StatelessWidget {
  const TableLayout({
    super.key,
    required this.header,
    required this.felt,
    required this.action,
    required this.hand,
    this.below,
  });

  /// The line along the top: the menu, the hand and the pass, the heart.
  final Widget header;

  /// The felt: the trick, the seats, and whatever floats over them.
  final Widget felt;

  /// The line between the score and the hand: what the game wants.
  final Widget action;

  /// The hand, told whether width is spare — a landscape fan shows more
  /// of each card.
  final Widget Function(bool landscape) hand;

  /// A line between the score and the action, when a page has one.
  final Widget? below;

  /// Wider than tall by a margin: a near-square window is laid out as
  /// portrait, where the fan is the part that needs the width.
  static bool isLandscape(BoxConstraints constraints) => constraints.maxWidth > constraints.maxHeight * 1.2;

  /// The hand's height in each composition: the fan sizes its cards from
  /// it, so the landscape hand is shorter cards shown wider.
  static const portraitHandHeight = 128.0;
  static const landscapeHandHeight = 100.0;

  /// The action line's row: as tall as its tallest state, the pass.
  static const actionRow = 54.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape = isLandscape(constraints);
        return Column(
          children: [
            header,
            // The four seats are all on the felt (ui/table_view.dart),
            // which takes what the rest leave: the line the table says
            // floats in the room under the near seat, so the felt runs
            // down to the action line.
            Expanded(child: felt),
            ?below,
            // The action line is about the hand, so it sits against it
            // — and keeps a row of the same height whatever it holds,
            // a note or the pass, so the table above never shifts
            // under it.
            ConstrainedBox(constraints: const BoxConstraints(minHeight: actionRow), child: action),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: SizedBox(
                height: landscape ? landscapeHandHeight : portraitHandHeight,
                child: hand(landscape),
              ),
            ),
          ],
        );
      },
    );
  }
}
