/// The table's composition, chosen from the space it is given
/// (docs/explanation/screens.md).
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
/// The table and its rail are one composition, centred together, so
/// on a screen wider than both the margins either side of them match.
/// And one scale for the lot (ui/scaled.dart): on a felt whose cards
/// grow, the type round them grows by as much.
///
/// Chosen from the constraints, never from the device: a phone turning,
/// a window dragged narrower, a foldable opening and a tablet in Split
/// View are one event, and the game's state lives above this widget, so
/// the turn keeps the hand.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hand_fan.dart';
import 'header.dart';
import 'scaled.dart';
import 'table_view.dart' show FeltRoom;

class TableLayout extends StatelessWidget {
  const TableLayout({
    super.key,
    required this.header,
    required this.felt,
    required this.action,
    required this.hand,
    this.below,
    this.note,
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

  /// A line between the felt and the action line, when a page has one.
  final Widget? below;

  /// What the table is teaching, where a page teaches (tutorial.dart):
  /// under the felt in portrait, and beside it in landscape, where the
  /// width is. The felt gives it the room either way, so it is over
  /// nothing the table shows. At the table's scale, like the action
  /// line, and never taller than [noteShare] of the table in portrait
  /// or than the felt in landscape: what does not fit scrolls
  /// (ui/coach_note.dart).
  final Widget? note;

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

  /// The most of the table's height a note takes in portrait; and how
  /// wide one is beside a felt in landscape, at a phone's scale, or the
  /// share of the table's width where that is less. The felt on its
  /// side keeps the width its flat trick and its badges want either way.
  static const noteShare = 0.4;
  static const noteWidth = 360.0;
  static const noteWidthShare = 0.5;

  /// The least room worth calling a rail. Narrower than this and the
  /// table simply takes the middle and leaves margins.
  static const railLeast = 260.0;

  /// The most: a rail wider than this is a rail with a column of air in
  /// it, and the table would rather have the width back.
  static const railMost = 420.0;

  /// The action line's row: as tall as its tallest state, the pass.
  /// At a phone's scale; it grows with the table's.
  static const actionRow = 54.0;

  /// The hand's row in a composition: its height and the padding round
  /// it.
  static double handRow({required bool landscape, required bool roomy}) =>
      (landscape
          ? (roomy ? roomyLandscapeHandHeight : landscapeHandHeight)
          : (roomy ? roomyPortraitHandHeight : portraitHandHeight)) +
      _handPadding.vertical;
  static const _handPadding = EdgeInsets.fromLTRB(8, 2, 8, 8);

  /// The scale of a table [width] wide in [height] of room, header and
  /// all: the felt's own (TableScale.forFelt), for the felt this
  /// layout leaves it. The felt is what the header, the action line and
  /// the hand leave, and the action line is drawn at the scale being
  /// found, so it is solved for rather than looked up: the scale that
  /// the felt left at that scale gives. Either the width decides it, or
  /// the height does, and the smaller of the two is the one that holds.
  static double scaleFor(double width, double height, {required bool landscape, required bool roomy}) {
    const k = TableScale.feltShare / TableScale.phoneCard;
    final base = height - TableHeader.height - handRow(landscape: landscape, roomy: roomy);
    final byWidth = k * width;
    final byHeight = k * base / (1 + k * actionRow);
    return (byWidth < byHeight ? byWidth : byHeight).clamp(1.0, TableScale.mostCard / TableScale.phoneCard);
  }

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
        final scale = scaleFor(forTable.maxWidth, forTable.maxHeight,
            landscape: isLandscape(forTable), roomy: roomy);
        final table = TableScale(scale: scale, child: _table(forTable, roomy: roomy, scale: scale));
        if (!roomy) return table;
        // The header is the app's own line and spans whatever there is;
        // under it the table holds its width and the rail sits beside
        // it, the two centred as one, so the margins either side of
        // them match.
        return Column(
          children: [
            header,
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: tableWidth, child: table),
                  if (railRoom > 0 && rail != null)
                    SizedBox(
                      width: railRoom,
                      child: Scaled(scale: scale, child: rail!(railRoom / scale)),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _table(BoxConstraints constraints, {required bool roomy, required double scale}) {
    final landscape = isLandscape(constraints);
    final handHeight = handRow(landscape: landscape, roomy: roomy) - _handPadding.vertical;
    // The action line spans the hand it is about: a whole hand's fan
    // and the margin either side of it, so its ends line up with the
    // fan's wherever the fan is narrower than the table — which is
    // everywhere but a phone upright, where the fan takes the width.
    final handReach = HandFan.fullWidth(handHeight, HandFan.spreadFor(landscape: landscape)) + _handPadding.horizontal;
    final reach = handReach < constraints.maxWidth ? handReach : constraints.maxWidth;
    final note = this.note;
    return Column(
      children: [
        if (!roomy) header,
        // The four seats are all on the felt (ui/table_view.dart),
        // which takes what the rest leave: the line the table says
        // floats in the room under the near seat, so the felt runs
        // down to the action line. A note shares the felt's room: in
        // portrait under it, as wide as the action line it sits on; in
        // landscape beside it, at the end the thumb is nearer, in
        // width the felt can spare, since the trick lies flat there
        // and it is height the felt lacks. The felt is laid out wide or
        // upright by the whole of the room (FeltRoom), so a note coming
        // and going changes how big the table is drawn, never how it is
        // laid out; and the felt keeps its place in the tree either
        // way, so nothing on it starts over when one comes.
        Expanded(
          child: LayoutBuilder(
            builder: (context, room) => FeltRoom(
              size: room.biggest,
              child: Flex(
                direction: landscape ? Axis.horizontal : Axis.vertical,
                children: [
                  Expanded(child: felt),
                  if (note != null && landscape)
                    SizedBox(
                      width: math.min(noteWidth * scale, constraints.maxWidth * noteWidthShare),
                      child: Scaled(
                        scale: scale,
                        child: Padding(padding: const EdgeInsetsDirectional.fromSTEB(2, 4, 10, 4), child: Center(child: note)),
                      ),
                    )
                  else if (note != null)
                    Center(
                      child: SizedBox(
                        width: reach,
                        child: Scaled(
                          scale: scale,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: constraints.maxHeight * noteShare / scale),
                            child: Padding(padding: const EdgeInsets.fromLTRB(10, 2, 10, 4), child: Center(heightFactor: 1, child: note)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        ?below,
        // The action line is about the hand, so it sits against it
        // — and keeps a row of the same height whatever it holds,
        // a note or the pass, so the table above never shifts
        // under it. At the table's scale: its type and the Pass button
        // grow with the cards.
        Center(
          child: SizedBox(
            width: reach,
            child: Scaled(
              scale: scale,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: actionRow),
                child: action,
              ),
            ),
          ),
        ),
        Padding(
          padding: _handPadding,
          child: SizedBox(height: handHeight, child: hand(landscape)),
        ),
      ],
    );
  }
}
