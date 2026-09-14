/// The table's composition, chosen from the space it is given
/// (docs/05-form-factors.md).
///
/// Top to bottom: the header (menu, where the game stands, the heart),
/// the felt, the player's own score, the action line, the hand. In
/// portrait the score is not a row of its own: the player is the fourth
/// seat on the felt, a badge the same gap from the cards as the other
/// three, and the action line floats in the band below. The
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
    required this.score,
    required this.action,
    required this.hand,
    this.below,
  });

  /// The line along the top: the menu, the hand and the pass, the heart.
  final Widget header;

  /// The felt: the trick, the seats, and whatever floats over them.
  final Widget felt;

  /// The player's own score, on its own row under the felt. The
  /// portrait composition does not use it: there the player's badge is
  /// the fourth seat on the felt itself (ui/table_view.dart).
  final Widget score;

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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape = isLandscape(constraints);
        return Column(
          children: [
            header,
            // In portrait the player's own badge is on the felt with
            // the other three, so what is left under it is one band,
            // and the action line floats in the middle of it. In
            // landscape the felt has no height to spare for a fourth
            // badge, so the score keeps its own row under the felt and
            // the action line sits on the next one.
            Expanded(flex: landscape ? 1 : 3, child: felt),
            if (landscape) score,
            ?below,
            if (landscape) action else Expanded(flex: 1, child: Center(child: action)),
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
