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
/// A third composition where there is room for one. A tablet is not a
/// big phone: past a width the table wants, spreading further buys
/// nothing but a fan you reach across the device to touch. So the table
/// holds that width and is centred, and whatever is left over is a rail
/// — the place for what a phone has to hide (ui/gone.dart). The felt
/// keeps the height, since the cards grow with it and a table wants to
/// be about as deep as it is wide.
///
/// Chosen from the constraints, never from the device: a phone turning,
/// a window dragged narrower, a foldable opening and a tablet in Split
/// View are one event, and the game's state lives above this widget, so
/// the turn keeps the hand.
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
    this.rail,
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

  /// What goes beside the table where there is room beside it, and
  /// nowhere at all where there is not. Given the width it has.
  final Widget Function(double width)? rail;

  /// Wider than tall by a margin: a near-square window is laid out as
  /// portrait, where the fan is the part that needs the width.
  static bool isLandscape(BoxConstraints constraints) => constraints.maxWidth > constraints.maxHeight * 1.2;

  /// The hand's height in each composition: the fan sizes its cards from
  /// it, so the landscape hand is shorter cards shown wider.
  static const portraitHandHeight = 128.0;
  static const landscapeHandHeight = 100.0;

  /// And on a roomy table, a little more of it: the hand is the part
  /// anybody actually touches, and there is height to spare.
  static const roomyPortraitHandHeight = 156.0;
  static const roomyLandscapeHandHeight = 124.0;

  /// The widest a table wants to be. Past this the fan has started
  /// running away from the thumbs.
  static const tableWidth = 900.0;

  /// The least room worth calling a rail. Narrower than this and the
  /// table simply takes the middle and leaves margins.
  static const railLeast = 260.0;

  /// The most: a rail wider than this is a rail with a column of air in
  /// it, and the table would rather have the width back.
  static const railMost = 420.0;

  /// The action line's row: as tall as its tallest state, the pass.
  static const actionRow = 54.0;

  /// How wide a rail gets beside a table in [width] of room; zero where
  /// there is no room for one.
  static double railFor(double width) {
    final over = width - tableWidth;
    return over < railLeast ? 0 : (over < railMost ? over : railMost);
  }

  /// Whether the table has more width than it wants, and is held to
  /// [tableWidth] rather than spreading into it.
  static bool isRoomy(BoxConstraints constraints) => constraints.maxWidth > tableWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final roomy = isRoomy(constraints);
        final railRoom = railFor(constraints.maxWidth);
        // The table's own shape is the shape of the space it is going
        // to be laid out in, not of the screen: a table with a rail
        // beside it is a narrower table, and picks its composition from
        // that.
        final forTable = constraints.copyWith(maxWidth: roomy ? tableWidth : constraints.maxWidth);
        final table = _table(forTable, roomy: roomy);
        if (!roomy) return table;
        // The header is the app's own line and spans whatever there is;
        // the table holds its width under it, and the rail takes what
        // the table left.
        return Column(
          children: [
            header,
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The table is centred in what is left when the rail
                  // has taken its width, so the trick sits where the
                  // eye goes.
                  Expanded(child: Center(child: SizedBox(width: tableWidth, child: table))),
                  if (railRoom > 0 && rail != null) SizedBox(width: railRoom, child: rail!(railRoom)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _table(BoxConstraints constraints, {required bool roomy}) {
    final landscape = isLandscape(constraints);
    return Column(
      children: [
        if (!roomy) header,
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
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: actionRow),
          child: action,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
          child: SizedBox(
            height: landscape
                ? (roomy ? roomyLandscapeHandHeight : landscapeHandHeight)
                : (roomy ? roomyPortraitHandHeight : portraitHandHeight),
            child: hand(landscape),
          ),
        ),
      ],
    );
  }
}
