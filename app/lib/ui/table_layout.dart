/// The table's composition, chosen from the space it is given
/// (docs/05-form-factors.md).
///
/// Top to bottom: the header (menu, where the game stands, the heart),
/// the felt, the action line, the hand. The player's own score is not a
/// row here: they are the fourth seat on the felt, a badge the same gap
/// from the cards as the other three (ui/table_view.dart). The
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape = isLandscape(constraints);
        return Column(
          children: [
            header,
            // The four seats are all on the felt (ui/table_view.dart).
            // Under it, portrait floats the action line in a band of
            // its own — a quarter of the height, the felt taking the
            // rest — while landscape, which has no height to spare,
            // gives it one row under the felt and no more.
            Expanded(flex: landscape ? 1 : 3, child: felt),
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
