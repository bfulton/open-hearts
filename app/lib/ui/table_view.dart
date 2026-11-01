/// The felt: opponents around the edge, the trick in the middle.
library;

import 'dart:math' as math;

import 'package:engine/engine.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/semantics.dart';

import '../l10n/l10n.dart';
import '../pacing.dart';
import '../table_model.dart';
import '../theme.dart';
import 'card_view.dart';
import 'pip.dart';
import 'player_icon.dart';
import 'reactions.dart';
import 'scaled.dart';

/// More height than a table is ever going to use, at which point where
/// it sits in the felt stops being a rounding error and starts being a
/// composition. Above a phone's own breathing room, so a phone's table
/// is centred in its felt.
const _roomToSpare = 240.0;

/// The badges' inset from the felt's edge, and the gap every badge
/// keeps from the card it labels. These and the pill's row are at a
/// phone's scale, and grow with the table's (ui/scaled.dart).
const _badgeInset = 6.0;
const _badgeGap = 8.0;

/// The line the table says — who took the trick, or that it is your
/// turn. In portrait it floats in the room the felt keeps under the
/// player's badge; on a wide felt there is no height for that and it
/// sits beside the badge, where there is width to spare.
const _pillRow = 30.0;

/// How much bigger the "your turn" pill is at the top of its breath.
const _breathing = 0.06;

/// Play runs 0-1-2-3, which reads clockwise once the seats are laid
/// out around the felt: the player at the near edge, then west, north
/// and east. Every seat wears a badge, the player's own included.
///
/// Which way each seat lies from the middle of the screen: the player
/// below, then west, north and east. The table places a seat's card
/// along it, a played card arrives along it, a swept trick leaves along
/// the winner's, and the hand sends a pass off the screen along the
/// receiver's (ui/hand_fan.dart).
const seatDirection = <int, Offset>{
  0: Offset(0, 1),
  1: Offset(-1, 0),
  2: Offset(0, -1),
  3: Offset(1, 0),
};

/// Where the three cards a player passes go, and where the three they
/// are passed come from: the seat at the other end of the pass, as a
/// direction on screen. Null on the hand that holds.
Offset? passesTo(TableModel controller) {
  final direction = controller.game.passDirection;
  if (direction == PassDirection.hold) return null;
  return seatDirection[controller.positionOf((controller.mySeat + direction.seatOffset) % seatCount)];
}

Offset? passesFrom(TableModel controller) {
  if (controller.game.passDirection == PassDirection.hold) return null;
  return seatDirection[controller.positionOf(controller.game.passerTo(controller.mySeat))];
}

/// The trick upright, as a pinwheel: north stepped to the west and
/// south to the east, so that west and east can come in beside them.
/// A phone upright is narrow before it is short, and the side badges
/// need their room beside the trick: a cross, north and south in the
/// middle, kept its cards smaller than the hand's (68 points to 76 on a
/// 390-point phone). This way they are the hand's size.
///
/// No card covers another's corner, where its rank and suit are, in
/// whichever order they are played. Taking a corner as the top left
/// 0.36 of a card's width and 0.45 of its height, centres in card
/// widths across and heights down: west at 0.72 is clear of north's
/// right edge with north 0.30 aside (0.72 ≥ 1 − 0.30), its own corner
/// clear of north's left edge (0.30 ≤ 0.72 − 0.36), and the far side
/// of the corner it would cover on south (0.72 ≥ 0.30 + 0.36); north
/// and south 0.6 out are clear of the middle row's tops and of each
/// other (0.6 ≥ 0.45, ≥ 0.5). The offsets are in steps of
/// [_stepAcross] card widths and [_stepDown] heights (_Trick).
const _trickOffset = <int, Offset>{
  0: Offset(0.30 / _stepAcross, 0.6 / _stepDown),
  1: Offset(-0.72 / _stepAcross, 0),
  2: Offset(-0.30 / _stepAcross, -0.6 / _stepDown),
  3: Offset(0.72 / _stepAcross, 0),
};

/// The step a trick's offsets are counted in: a slot one unit across
/// sits this many card widths from the middle, and one unit down this
/// many card heights.
const _stepAcross = 1.15, _stepDown = 1.02;

/// How tall the upright trick's block is, in card heights: its cards'
/// reach, 0.6 out each way and a card, and the margin the cross kept.
const _trickTall = 2 * 0.6 + 1 + 0.11;

/// The trick on a wide felt (a landscape phone), where height is what
/// is short: flatter and wider than upright, so the four cards keep
/// their size in the height the felt has.
const _wideTrickOffset = <int, Offset>{
  0: Offset(0, 0.62),
  1: Offset(-1.12, 0),
  2: Offset(0, -0.62),
  3: Offset(1.12, 0),
};

/// The room the trick's block takes, in card widths across and card
/// heights down: on a wide felt, and upright.
const _wideBlock = Size(3.6, 2.3);
const _uprightBlock = Size(2.9, _trickTall);

/// The narrowest a card on the felt is drawn, and still read.
const _leastCard = 34.0;

/// Whether the "your turn" pill breathes. A test that waits for the
/// table to come to rest turns it off, since a breath is a frame every
/// sixteen milliseconds for as long as the turn is yours
/// (test/flutter_test_config.dart); one test turns it back on to watch
/// it breathe.
@visibleForTesting
bool turnPillBreathes = true;

/// The room a felt has before anything is taken from it for a note
/// under or beside it (ui/table_layout.dart, note). The felt lays its
/// table out wide or upright by this, not by the room it is left: a
/// note coming and going changes how big the table is drawn, never how
/// it is laid out.
class FeltRoom extends InheritedWidget {
  const FeltRoom({super.key, required this.size, required super.child});

  final Size size;

  static Size? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<FeltRoom>()?.size;

  @override
  bool updateShouldNotify(FeltRoom old) => old.size != size;
}

class TableView extends StatelessWidget {
  const TableView({super.key, required this.controller, this.onHold, this.corner, this.react});

  final TableModel controller;

  /// Holding a seat's badge, where the page has something to offer
  /// about that player — at a live table, what to do about their
  /// picture. Null leaves the badge alone.
  final void Function(int seat)? onHold;

  /// A line in the felt's top corner, where the page has one — at a
  /// live table, who is here — and the colour it is said in.
  final ({String text, Color tone})? corner;

  /// The player's way to react, beside their own badge, where the page
  /// has one: at a live table they sit at, the button that opens the
  /// reactions (ui/reactions.dart). Their own reaction takes its place
  /// while it shows, and the button is back when it goes.
  final Widget? react;

  @override
  Widget build(BuildContext context) {
    final shooter = controller.game.moonShooter;
    return _MoonQuake(
      shooter: shooter == null ? null : controller.positionOf(shooter),
      builder: (context, badges) => _felt(context, badges),
    );
  }

  /// The felt, its badges keyed by position for the quake to find.
  Widget _felt(BuildContext context, List<GlobalKey> badges) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final at = _FeltLayout(context, constraints.biggest, corner);
        final box = at.box;
        final scale = at.scale;
        final edge = at.edge;
        final badgeGap = at.badgeGap;
        final line = at.line;
        final gap = at.gap;
        final trickBox = at.trickBox;
        final sideRoom = at.sideRoom;
        final wide = at.wide;
        final note = corner;

        Widget seat(int position) => _Seat(view: this, at: at, position: position, badgeKey: badges[position]);
        Widget? bubble(int position, AxisDirection tail) => _bubble(controller, position, tail, scale);

        // The player's own corner: the button, or their reaction.
        final mine = bubble(0, wide ? AxisDirection.right : AxisDirection.left) ?? (react == null ? null : Scaled(scale: scale, child: react!));
        final pill = _says(controller);

        final table = Padding(
          padding: EdgeInsets.symmetric(horizontal: edge),
          child: Column(
            children: [
              SizedBox(height: at.above),
              // The far badge holds the middle, as it always has, and its
              // reaction comes in on the left of it.
              SizedBox(
                height: line,
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(left: at.northReserve, right: badgeGap),
                        child: Align(alignment: Alignment.centerRight, child: _Shows(bubble(2, AxisDirection.right))),
                      ),
                    ),
                    seat(2),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ),
              SizedBox(height: gap),
              SizedBox(
                height: trickBox.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      right: at.sideOut,
                      width: sideRoom,
                      top: 0,
                      bottom: -at.westDown,
                      child: _SideSeat(
                        badge: seat(1),
                        bubble: _Shows(bubble(1, AxisDirection.up)),
                        home: Rect.fromLTWH(0, 0, sideRoom, trickBox.height),
                        anchoredRight: true,
                        up: false,
                        gap: badgeGap,
                        clear: at.clearOfFacing,
                      ),
                    ),
                    Positioned(
                      left: at.sideOut,
                      width: sideRoom,
                      top: -at.eastUp,
                      bottom: 0,
                      child: _SideSeat(
                        badge: seat(3),
                        bubble: _Shows(bubble(3, AxisDirection.down)),
                        home: Rect.fromLTWH(0, at.eastUp, sideRoom, trickBox.height),
                        anchoredRight: false,
                        up: true,
                        gap: badgeGap,
                        clear: at.clearOfFacing,
                      ),
                    ),
                    Align(alignment: Alignment.center, child: _Trick.of(controller, at)),
                  ],
                ),
              ),
              SizedBox(height: gap),
              if (wide)
                // The line beside the badge, with the same room kept on
                // the other side of it, so the badge holds the middle
                // whether or not there is anything to say. In the
                // badge's row: a wide felt has no height to give it a
                // row of its own. The room on the other side is the
                // player's own corner.
                SizedBox(
                  height: line,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: badgeGap),
                          child: Align(alignment: Alignment.centerRight, child: _Shows(mine)),
                        ),
                      ),
                      seat(0),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Scaled(
                            scale: scale,
                            child: Padding(padding: const EdgeInsets.only(left: 12), child: _Said(child: pill)),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                // The near badge holds the middle too, and the player's
                // own corner is beside it.
                SizedBox(
                  height: line,
                  child: Row(
                    children: [
                      const Expanded(child: SizedBox.shrink()),
                      seat(0),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: badgeGap),
                          child: Align(alignment: Alignment.centerLeft, child: _Shows(mine)),
                        ),
                      ),
                    ],
                  ),
                ),
                // The room under the near seat, with the line the table
                // says in the middle of it: the action line has the row
                // against the hand (table_layout.dart).
                Expanded(child: Center(child: Scaled(scale: scale, child: _Said(child: pill)))),
              ],
              if (wide) const Spacer(),
            ],
          ),
        );
        final felt = note == null
            ? table
            : Stack(
                children: [
                  table,
                  Positioned(
                    left: edge,
                    top: edge,
                    child: Scaled(
                      scale: scale,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: (box.width - 2 * edge) / scale),
                        child: FeltCorner(text: note.text, tone: note.tone),
                      ),
                    ),
                  ),
                ],
              );
        if (at.cluster <= box.height) return felt;
        // Shorter than the least of a table: the smallest trick, its
        // badges and the line, which only the largest type on a phone
        // on its side comes to. The table is drawn smaller to fit
        // rather than run off the felt, every part of it together, so
        // nothing is cut and nothing lands on anything else.
        return SizedBox.fromSize(
          size: box,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(width: box.width, height: at.cluster, child: felt),
          ),
        );
      },
    );
  }
}

/// Where everything on a felt [box] big goes: how big the cards are,
/// how much room each badge has, and where the rows fall.
class _FeltLayout {
  _FeltLayout(BuildContext context, this.box, ({String text, Color tone})? note) {
    // How much bigger than a phone's this table is drawn: its
    // layout's, or on a felt of its own, the felt's.
    scale = TableScale.maybeOf(context) ?? TableScale.forFelt(box);
    edge = _badgeInset * scale;
    badgeGap = _badgeGap * scale;
    // The row for the line the table says grows with the line, at the
    // reader's text size: what the felt says is read, and the trick
    // is what gives way to it. In portrait it floats in the room
    // under the near seat, which is its row and a phone's row of air.
    final pillRow = (_pillRow + _Pill.growth(context)) * scale;
    final pillRoom = pillRow + _pillRow * scale;
    // A wide felt — a landscape phone — lays the trick out flatter
    // and its badges on one line, since height is what it lacks. Wide
    // by its whole room, where a note has taken some of it (FeltRoom).
    final room = FeltRoom.maybeOf(context) ?? box;
    wide = room.width > room.height * 1.3;
    offsets = wide ? _wideTrickOffset : _trickOffset;
    final block = wide ? _wideBlock : _uprightBlock;
    // The line in the corner sits beside the seat across the felt
    // where there is room for it: clear of the widest that seat's
    // badge can be (the trick's own width), and above where the side
    // seats' badges can start — the trick's top for a stacked one,
    // which can be as tall as the trick, and on a wide felt the
    // middle of the smallest trick, where a badge of one line sits.
    // Where there is not — a phone upright, or large type — it has a
    // strip of its own at the top, and the table comes down under
    // it. Drawn at the table's scale.
    final noteSize = note == null ? Size.zero : FeltCorner.sizeOf(context, note.text, (box.width - 2 * edge) / scale) * scale;
    // The side badges' room: from the felt's edge to the trick's
    // outer card, less a gap. A name has to fit it, wrapped if it
    // must; and on a felt too narrow for both, the trick gives way
    // rather than running under the badges. Upright, that is what
    // holds a card's width: as wide as leaves the side badges their
    // least, which is the hand's size from a 360-point phone up. On
    // a wide felt the trick lies flat and a share of the width does.
    final reach = offsets[3]!.dx * _stepAcross + 0.5; // the east card's far edge, in card widths from the middle
    double sideRoomFor(double cw) => box.width / 2 - cw * reach - edge - badgeGap;
    final leastRoom = SeatBadge.leastWidth * scale;
    final across = wide ? box.width * 0.16 : (box.width / 2 - edge - badgeGap - leastRoom) / reach;
    final widest = block.width * math.min(across, TableScale.phoneCard * scale);
    final tight = SeatBadge.tightLine * scale;
    final sidesFrom = tight + (wide ? math.max(0.0, (cardHeightFor(_leastCard) * _wideBlock.height - tight) / 2) : 0.0);
    final beside = edge + noteSize.width + badgeGap <= (box.width - widest) / 2 && edge + noteSize.height + badgeGap <= sidesFrom;
    final noteRow = note == null || beside ? 0.0 : edge + noteSize.height + badgeGap;
    // The badges hold to their cards, so it is the trick that gives
    // way, never the layout that overflows: the two facing badges
    // and their gaps — and in portrait the row kept for the line
    // under the table — come off the height before the trick is
    // sized, and it takes what is left of whichever dimension runs
    // out first.
    // Portrait keeps room under the near badge for the line the
    // table says, and a row of air, so the line sits in the middle
    // of it rather than against the badge. And a badge is as tall
    // as a face wants unless that would leave the cards under what
    // a card can be read at, where it takes the smaller size back.
    double cardsUnder(double line) =>
        (box.height - noteRow - 2 * (line + badgeGap) - (wide ? 0.0 : pillRoom)) / (block.height / cardAspect);
    line = (cardsUnder(SeatBadge.line * scale) >= _leastCard ? SeatBadge.line : SeatBadge.tightLine) * scale;
    // The biggest a card is allowed to be, from the felt's own
    // size. A phone is held at arm's length and its felt is small,
    // so seventy-six points is the whole of what fits; a tablet's
    // felt is further away and has room, and cards that stayed a
    // phone's size on it would be a phone's game with green around
    // it (docs/explanation/screens.md). That is the table's scale, the
    // one its type is drawn at too.
    final most = TableScale.phoneCard * scale;
    var cardWidth = [
      across,
      cardsUnder(line),
      most,
    ].reduce((a, b) => a < b ? a : b).clamp(_leastCard, most);
    if (sideRoomFor(cardWidth) < leastRoom) {
      cardWidth = ((box.width / 2 - edge - badgeGap - leastRoom) / reach).clamp(_leastCard, cardWidth);
    }
    this.cardWidth = cardWidth;
    sideRoom = sideRoomFor(cardWidth).clamp(leastRoom, box.width);
    cardHeight = cardHeightFor(cardWidth);
    trickBox = Size(cardWidth * block.width, cardHeight * block.height);

    // A badge hugs what it says, up to the room it has: the width
    // of the trick's own column for the seat across the felt and
    // your own, and the strip between a card and the felt's edge
    // for the two at the sides.
    facing = trickBox.width;
    // The side strips start nearer the middle than the far and near
    // badges may reach, the pinwheel having brought the side cards
    // in: a side seat's reaction, which can run up or down into those
    // badges' rows, keeps this far in from its strip's inner edge.
    clearOfFacing = math.max(0.0, facing / 2 - cardWidth * reach);

    // All four seats are on the felt, each badge the same gap from
    // the card it labels, so every badge reads as that card's
    // label. The trick's block is a little deeper than the cards in
    // it, which the gaps above and below take off. What is left
    // over is the rail: in portrait it goes to the far end, above
    // the seat across the table, because the band under the felt
    // already floats the action line (table_layout.dart); on a wide
    // felt, where the action line sits on a row of its own, it is
    // split evenly and the table rides in the middle.
    final inset = trickBox.height / 2 - (offsets[2]!.dy.abs() * cardHeight * _stepDown + cardHeight / 2);
    gap = (badgeGap - inset).clamp(0.0, badgeGap);
    // Where a side badge's inner edge falls: a gap out from the far
    // edge of the card beside it, measured from the middle of the
    // felt.
    sideOut = (box.width - 2 * edge) / 2 + cardWidth * reach + badgeGap;

    // Where the table sits in the felt. A phone's felt is the size
    // of its table and the slack is a few points either way, so it
    // is centred and that is that. A tablet's has height the cards
    // will never grow into, and there the table sits low: the room
    // beyond the far seat reads as the far end of the table, while
    // the room under your own badge is the gap between you and your
    // own cards, and wants to be small.
    cluster = noteRow + 2 * line + 2 * gap + trickBox.height + (wide ? 0.0 : pillRoom);
    final slack = (box.height - cluster).clamp(0.0, double.infinity);
    above = noteRow + (slack > _roomToSpare ? slack * 0.7 : slack / 2);

    // The line in the corner, where it shares a row with the far
    // seat — beside it, on a wide felt — is room the far seat's
    // reaction keeps clear of; and where it runs across the top of
    // the felt, the right-hand seat's keeps under it.
    final noteBottom = edge + noteSize.height;
    northReserve = note != null && beside && noteBottom > above && edge < above + line ? noteSize.width + badgeGap : 0.0;
    final eastTop = note != null && noteSize.width > sideOut ? noteBottom + badgeGap : edge;
    // How far the side seats' reactions may run: over the right-hand
    // badge up to the top of the felt, and under the left-hand one
    // down past the near seat's row — the player's own reaction and
    // the button are on the other side of it. On a wide felt the far
    // and near badges may run as wide as the side strips, and the two
    // keep to the trick's own rows.
    final trickTop = above + line + gap;
    eastUp = wide ? gap : math.max(0.0, trickTop - eastTop);
    westDown = wide ? gap : gap + line;
  }

  /// The felt's own size.
  final Size box;

  /// How much bigger than a phone's this table is drawn, and the
  /// badges' inset from the felt's edge and gap from their cards at it.
  late final double scale, edge, badgeGap;

  /// Whether the felt is wide — a landscape phone — and the trick lies
  /// flat, and where each seat's card sits in it.
  late final bool wide;
  late final Map<int, Offset> offsets;

  /// A badge's row, the cards, and the trick's block.
  late final double line, cardWidth, cardHeight;
  late final Size trickBox;

  /// The room a badge has: across the felt and at the near edge
  /// ([facing]), and at the sides ([sideRoom]), whose inner edge is
  /// [sideOut] from the middle; and how far a side seat's reaction keeps
  /// in from it ([clearOfFacing]).
  late final double facing, sideRoom, sideOut, clearOfFacing;

  /// The gap between a badge's row and the trick, the room above the far
  /// seat, and the height of the whole table.
  late final double gap, above, cluster;

  /// How much of the far seat's row the line in the corner keeps from
  /// its reaction, and how far the side seats' reactions run past their
  /// strips: the right-hand one up, the left-hand one down.
  late final double northReserve, eastUp, westDown;
}

/// A seat's badge on the felt. Each badge hugs its name, so the two of a
/// pair — the seats across from each other — are each laid out over a
/// ghost of the other, which takes up its room and draws nothing:
/// whichever name is the longer, the pair come out one size.
class _Seat extends StatelessWidget {
  const _Seat({required this.view, required this.at, required this.position, required this.badgeKey});

  final TableView view;
  final _FeltLayout at;
  final int position;

  /// The badge's own, not its ghosts': where a moon's quake starts.
  final GlobalKey badgeKey;

  /// A badge is laid out at a phone's scale and drawn at the table's, so
  /// the room it is given here is in a phone's points.
  Widget _badge(int position) {
    final controller = view.controller;
    final game = controller.game;
    final seat = controller.seatAt(position);
    final scale = at.scale;
    final wide = at.wide;
    return SeatBadge(
      onHold: view.onHold == null ? null : () => view.onHold!(controller.seatAt(position)),
      seat: seat,
      position: position,
      look: controller.lookOf(seat),
      game: game,
      onTurn: game.currentSeat == seat,
      // A trick with points in it is told by the glow round the badge
      // (_PointsGlow), and one way of saying it is enough.
      won: game.pendingTrick?.winner == seat && pointsIn(game.pendingTrick!.plays.map((p) => p.card)) == 0,
      clockMs: controller.clockMs(seat),
      // The seat across the felt reads the same way as the
      // player's own line at the near edge: one line, icon
      // first. The side badges have a strip, so they stack.
      oneLine: wide || position.isEven,
      maxWidth: (!wide && position.isEven ? at.facing : at.sideRoom) / scale,
      // A stacked badge takes the height of the row it is in,
      // which is the taller of the pair's (below).
      height: wide || position.isEven ? at.line / scale : null,
      iconSize: wide || position.isEven ? SeatBadge.iconOn(at.line / scale) : SeatBadge.iconIn(at.cardHeight / scale),
    );
  }

  @override
  Widget build(BuildContext context) {
    final game = view.controller.game;
    final seat = view.controller.seatAt(position);
    final pending = game.pendingTrick;
    final pair = Stack(
      children: [
        // The two ghosts make the box; the badge fills it.
        BadgeGhost(child: _badge(position)),
        BadgeGhost(child: _badge((position + 2) % seatCount)),
        Positioned.fill(
          child: _PointsGlow(
            key: badgeKey,
            position: position,
            trick: pending?.winner == seat ? [for (final p in pending!.plays) p.card] : null,
            child: _badge(position),
          ),
        ),
      ],
    );
    // A side badge is anchored by its inner edge, a gap out from
    // its card (below), and runs out towards the felt's edge as
    // far as its name takes it. It is as tall as its name and
    // numbers make it, up to the trick's own height, between the
    // badges above and below it: past that, at the largest type
    // on the smallest felt, it scales what it holds into that.
    return Scaled(
      scale: at.scale,
      child: at.wide || position.isEven
          ? SizedBox(height: at.line / at.scale, child: pair)
          : ConstrainedBox(constraints: BoxConstraints(maxHeight: at.trickBox.height / at.scale), child: pair),
    );
  }
}

/// Where a seat's badge glows: what paints round the badge at
/// [position].
@visibleForTesting
Key pointsGlowAt(int position) => ValueKey('points glow $position');

/// A seat's badge, glowing for a trick with points in it that the seat
/// has won: pink, for points taken (theme.dart), and red, the game's
/// own, for a trick with the queen in it. It comes up as the trick is
/// won, in place of the white border a trick without points gives its
/// winner, and holds while the trick is on the table and swept to the
/// seat (_Trick); once the cards are in, it holds for half its time and
/// fades over the other half, the queen's half a second longer. Where
/// the device asks for less motion nothing is swept, and that time
/// starts as the trick is taken. A trick that was never seen on the
/// table, as when it catches up with itself, glows nowhere.
class _PointsGlow extends StatefulWidget {
  const _PointsGlow({super.key, required this.position, required this.trick, required this.child});

  final int position;

  /// The finished trick's cards, while it is on the table and the
  /// seat's; null at every other moment.
  final List<Card>? trick;

  final Widget child;

  @override
  State<_PointsGlow> createState() => _PointsGlowState();
}

class _PointsGlowState extends State<_PointsGlow> with TickerProviderStateMixin {
  /// The glow coming up as the trick is won; and, from when it is taken,
  /// the sweep and the glow's time after the cards are in.
  late final AnimationController _up = AnimationController(vsync: this);
  late final AnimationController _down = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _up.value = 0;
    });

  /// The glow's colour, how long the sweep is, and how long the glow
  /// lasts once the cards are in.
  Color _colour = Palette.pink;
  Duration _waits = Duration.zero;
  Duration _lasts = Pacing.pointsGlow;

  @override
  void initState() {
    super.initState();
    if (widget.trick != null) _won(widget.trick!);
  }

  @override
  void dispose() {
    _up.dispose();
    _down.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_PointsGlow old) {
    super.didUpdateWidget(old);
    if (listEquals(old.trick, widget.trick)) return;
    // The trick that was on the table as this seat's has gone from it:
    // taken, and on its way to the seat.
    if (old.trick != null && _up.value > 0 && !_down.isAnimating) {
      final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      _waits = still ? Duration.zero : Pacing.trickSweeps;
      _down
        ..duration = _waits + _lasts
        ..forward(from: 0);
    }
    if (widget.trick != null) _won(widget.trick!);
  }

  /// [trick], with points in it, won by the seat and on the table: the
  /// glow comes up, from as strong as it is if the last is still going.
  void _won(List<Card> trick) {
    if (pointsIn(trick) == 0) return;
    final queen = trick.contains(queenOfSpades);
    final now = _strength;
    _colour = queen ? Palette.red : Palette.pink;
    _lasts = queen ? Pacing.queenGlow : Pacing.pointsGlow;
    _down
      ..stop()
      ..value = 0;
    _up
      ..value = now
      ..animateTo(1, duration: _lasts * (0.15 * (1 - now)), curve: Curves.easeOut);
  }

  /// How strong the glow is: up quickly as the trick is won, held until
  /// the cards are in and half its time after, and gone over the other
  /// half. Nothing once it has run.
  double get _strength {
    final up = _up.value;
    if (!_down.isAnimating) return up;
    final past = _down.value * _down.duration!.inMicroseconds - (_waits + _lasts * 0.5).inMicroseconds;
    final fades = _lasts.inMicroseconds / 2;
    return past <= 0 ? up : up * Curves.easeInOut.transform(1 - past / fades);
  }

  @override
  Widget build(BuildContext context) => CustomPaint(key: pointsGlowAt(widget.position), painter: _Glow(this), child: widget.child);
}

/// A glow round a badge, as strong as [glow] says: bright against its
/// edge, and wide and soft beyond, which a dark red needs to be seen on
/// the felt at all. Round the badge and not through it, so what it says
/// is read as it always is.
class _Glow extends CustomPainter {
  _Glow(this.glow) : super(repaint: Listenable.merge([glow._up, glow._down]));

  final _PointsGlowState glow;

  /// The blur of the bright edge and of the soft glow beyond it, and how
  /// far out each is drawn from the badge at full strength.
  static const _edge = (sigma: 4.0, out: 2.0);
  static const _soft = (sigma: 15.0, out: 8.0);

  @override
  void paint(Canvas canvas, Size size) {
    final s = glow._strength;
    if (s == 0) return;
    final badge = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(13));
    final reach = _soft.out + 3 * _soft.sigma;
    final paint = Paint();
    canvas
      ..save()
      ..clipPath(Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(reach))
        ..addRRect(badge))
      ..drawRRect(
          badge.inflate(_edge.out * s),
          paint
            ..color = glow._colour.withValues(alpha: s)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, _edge.sigma))
      ..drawRRect(
          badge.inflate(_soft.out * s),
          paint
            ..color = glow._colour.withValues(alpha: 0.75 * s)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, _soft.sigma))
      ..restore();
  }

  @override
  bool shouldRepaint(_Glow old) => old.glow != glow;

  /// Decoration: what is under it is touched, not it.
  @override
  bool hitTest(Offset position) => false;
}

/// The felt, shaken when a hand ends with a moon, whoever shot it: the
/// moment the last trick reaches the seat that took every point, the
/// table jolts away from it and settles, and rings run out across the
/// felt from that seat's badge, under everything on it. Over within the
/// beat of bare felt before the sheet (Pacing.moonQuake). Nothing at all
/// where the device asks for less motion; the sheet says who shot it.
class _MoonQuake extends StatefulWidget {
  const _MoonQuake({required this.shooter, required this.builder});

  /// The position of the seat that shot the moon in the hand just over;
  /// null while there is none.
  final int? shooter;

  /// The felt, given a key for each position's badge.
  final Widget Function(BuildContext context, List<GlobalKey> badges) builder;

  @override
  State<_MoonQuake> createState() => _MoonQuakeState();
}

class _MoonQuakeState extends State<_MoonQuake> with SingleTickerProviderStateMixin {
  final _badges = List.generate(seatCount, (_) => GlobalKey());

  /// The felt inside the shake, which is where it is at rest.
  final _felt = GlobalKey();

  /// The sweep to the shooter, and then the quake.
  late final AnimationController _quake = AnimationController(vsync: this, duration: Pacing.trickSweeps + Pacing.moonQuake);

  /// The position that shot the moon, and which way the felt jolts
  /// first: from it towards the middle.
  int _shooter = 0;
  Offset _away = Offset.zero;

  @override
  void dispose() {
    _quake.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_MoonQuake old) {
    super.didUpdateWidget(old);
    // A moon that has just been shot, not one already on the felt when
    // it was opened.
    final shooter = widget.shooter;
    if (shooter == null || old.shooter != null) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _shooter = shooter;
    _away = -seatDirection[shooter]!;
    _quake.forward(from: 0);
  }

  /// The middle of the shooter's badge, where the felt has it at rest:
  /// asked while the felt is painted, once it has been laid out.
  Offset? get _epicentre {
    final badge = _badges[_shooter].currentContext?.findRenderObject() as RenderBox?;
    final felt = _felt.currentContext?.findRenderObject() as RenderBox?;
    if (badge == null || felt == null || !badge.attached || !badge.hasSize) return null;
    return badge.localToGlobal(badge.size.center(Offset.zero), ancestor: felt);
  }

  /// How far into the quake: zero through the sweep, then up to one.
  double get _t {
    final waits = Pacing.trickSweeps.inMicroseconds / _quake.duration!.inMicroseconds;
    return ((_quake.value - waits) / (1 - waits)).clamp(0.0, 1.0);
  }

  /// Where the felt is shaken to: back and forth along the line from the
  /// shooter, a little across it, dying away; still at either end.
  Offset _shake(Size size) {
    final t = _t;
    final most = size.shortestSide * 0.02 * math.pow(1 - t, 2);
    final across = Offset(-_away.dy, _away.dx);
    return _away * most * math.sin(t * math.pi * 10) + across * most * 0.35 * math.sin(t * math.pi * 14);
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _Rings(this),
      child: AnimatedBuilder(
        animation: _quake,
        builder: (context, child) => LayoutBuilder(
          builder: (context, room) => Transform.translate(offset: _shake(room.biggest), child: child),
        ),
        child: KeyedSubtree(key: _felt, child: widget.builder(context, _badges)),
      ),
    );
  }
}

/// The quake's rings, from the shooter's badge to past the felt's
/// furthest corner.
class _Rings extends CustomPainter {
  _Rings(this.quake) : super(repaint: quake._quake);

  final _MoonQuakeState quake;

  /// When each ring sets out, and how long it takes to run its course,
  /// as shares of the quake.
  static const _starts = [0.0, 0.14, 0.28];
  static const _runs = 0.6;

  @override
  void paint(Canvas canvas, Size size) {
    final t = quake._t;
    if (t == 0 || t == 1) return;
    final from = quake._epicentre;
    if (from == null) return;
    final reach = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((corner) => (corner - from).distance).reduce(math.max);
    final ring = Paint()..style = PaintingStyle.stroke;
    for (final start in _starts) {
      final p = (t - start) / _runs;
      if (p <= 0 || p >= 1) continue;
      ring
        ..color = Palette.chrome.withValues(alpha: 0.5 * math.pow(1 - p, 1.5))
        ..strokeWidth = size.shortestSide * 0.012 * (1 - p) + 1;
      canvas.drawCircle(from, reach * Curves.easeOut.transform(p), ring);
    }
  }

  @override
  bool shouldRepaint(_Rings old) => old.quake != quake;

  /// Decoration: what is under it is touched, not it.
  @override
  bool hitTest(Offset position) => false;
}

/// A seat's reaction while it shows (ui/reactions.dart), beside its
/// badge in room nothing else is drawn in, and never over a card: across
/// the felt, to the left of the far badge; at the sides, over the
/// right-hand badge and under the left-hand one, each in the strip its
/// badge stands in, so the two run off into opposite corners and neither
/// meets the seats across; and at the near edge the player's own, in the
/// place of the button that sent it, on the far side of the badge from
/// the left-hand seat's. Drawn at the table's scale, as big as the room
/// lets it be. The tail points at the badge. Null while the seat has
/// none up.
Widget? _bubble(TableModel controller, int position, AxisDirection tail, double scale) {
  final seat = controller.seatAt(position);
  final shown = controller.reactionAt(seat);
  if (shown == null) return null;
  return Scaled(
    key: ValueKey(shown.n),
    scale: scale,
    child: ReactionBubble(reaction: shown.reaction, name: controller.nameAlone(seat), tail: tail),
  );
}

/// [child] coming and going, or nothing.
class _Shows extends StatelessWidget {
  const _Shows(this.child);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedSwitcher(
      duration: still ? Duration.zero : const Duration(milliseconds: 180),
      child: child ?? const SizedBox.shrink(),
    );
  }
}

/// Under the trick, never across it: who took it, or whose turn it is.
Widget _says(TableModel controller) {
  final game = controller.game;
  final pending = game.pendingTrick;
  return pending != null
      ? _TrickResult(
          you: pending.winner == controller.mySeat,
          name: controller.names[pending.winner],
          points: pointsIn(pending.plays.map((p) => p.card)),
        )
      : game.phase == Phase.playing && controller.pendingPlay == null
          ? _TurnHint(game: game, mySeat: controller.mySeat)
          : const SizedBox.shrink();
}

Card? _cardFrom(HeartsGame game, int seat) {
  for (final p in game.trick) {
    if (p.seat == seat) return p.card;
  }
  return null;
}

/// Where in the trick [seat]'s card was played: 0 led it.
int? _orderOf(HeartsGame game, int seat) {
  for (var i = 0; i < game.trick.length; i++) {
    if (game.trick[i].seat == seat) return i;
  }
  return null;
}

/// A side badge where it has always been — held against its card by
/// its inner edge, in the middle of the trick's height ([home]) — and
/// its reaction beside it, over or under it in the strip the badge
/// stands in, as far as this box runs: the felt gives the box the room
/// past the trick that the reaction may have (TableView).
class _SideSeat extends StatelessWidget {
  const _SideSeat({
    required this.badge,
    required this.bubble,
    required this.home,
    required this.anchoredRight,
    required this.up,
    required this.gap,
    this.clear = 0,
  });

  final Widget badge;
  final Widget bubble;
  final Rect home;

  /// Which side of the strip the badge holds to: the one against the
  /// trick.
  final bool anchoredRight;

  /// Whether the reaction goes over the badge, rather than under it.
  final bool up;
  final double gap;

  /// How far in from the strip's inner edge the reaction keeps: clear of
  /// the far and near badges' column, which it can run alongside.
  final double clear;

  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
        delegate: _SideSeatLayout(home: home, anchoredRight: anchoredRight, up: up, gap: gap, clear: clear),
        children: [
          LayoutId(id: _SideSeatLayout.badge, child: badge),
          LayoutId(id: _SideSeatLayout.bubble, child: bubble),
        ],
      );
}

class _SideSeatLayout extends MultiChildLayoutDelegate {
  _SideSeatLayout({required this.home, required this.anchoredRight, required this.up, required this.gap, required this.clear});

  static const badge = 'badge';
  static const bubble = 'bubble';

  final Rect home;
  final bool anchoredRight;
  final bool up;
  final double gap;
  final double clear;

  @override
  void performLayout(Size size) {
    final b = layoutChild(badge, BoxConstraints.loose(home.size));
    final at = Offset(anchoredRight ? home.right - b.width : home.left, home.top + (home.height - b.height) / 2);
    positionChild(badge, at);
    // From a gap off the badge to the end of the box, the strip's width.
    final top = up ? 0.0 : at.dy + b.height + gap;
    final bottom = up ? at.dy - gap : size.height;
    // The strip less what it keeps clear of on its inner side: the left
    // of the right-hand strip, the right of the left-hand one.
    final from = anchoredRight ? 0.0 : clear;
    final to = anchoredRight ? size.width - clear : size.width;
    final r = layoutChild(bubble, BoxConstraints.loose(Size(math.max(0.0, to - from), math.max(0.0, bottom - top))));
    // Over or under the middle of the badge, inside the strip.
    final x = (at.dx + b.width / 2 - r.width / 2).clamp(from, math.max(from, to - r.width)).toDouble();
    positionChild(bubble, Offset(x, up ? bottom - r.height : top));
  }

  @override
  bool shouldRelayout(_SideSeatLayout old) =>
      old.home != home || old.anchoredRight != anchoredRight || old.up != up || old.gap != gap || old.clear != clear;
}

/// The middle of the felt: four slots that hold their place, whatever
/// is in them. A card arrives from the side of the screen its player
/// sits on, and the finished trick leaves towards whoever took it — so
/// both movements say who, and neither needs a word.
class _Trick extends StatefulWidget {
  const _Trick({
    required this.size,
    required this.offsets,
    required this.cardWidth,
    required this.cardHeight,
    required this.cards,
    required this.orders,
    required this.names,
    required this.winner,
  });

  final Size size;
  final Map<int, Offset> offsets;
  final double cardWidth;
  final double cardHeight;

  /// By position, the near seat first: what is on the table, where in
  /// the trick it was played, and whose it is.
  final List<Card?> cards;
  final List<int?> orders;
  final List<String> names;

  /// The position that has taken the finished trick, while it is still
  /// on the table; null at every other moment.
  final int? winner;

  /// The trick as [controller] has it, as one centred block laid out as
  /// [at] says. Slots hold their place so arriving cards never shove
  /// the layout around.
  factory _Trick.of(TableModel controller, _FeltLayout at) {
    final game = controller.game;
    final pending = game.pendingTrick;
    return _Trick(
      size: at.trickBox,
      offsets: at.offsets,
      cardWidth: at.cardWidth,
      cardHeight: at.cardHeight,
      cards: [
        for (var position = 0; position < seatCount; position++)
          _cardFrom(game, controller.seatAt(position)) ?? (position == 0 ? controller.pendingPlay : null),
      ],
      orders: [
        for (var position = 0; position < seatCount; position++)
          _orderOf(game, controller.seatAt(position)) ??
              (position == 0 && controller.pendingPlay != null ? game.trick.length : null),
      ],
      names: [
        for (var position = 0; position < seatCount; position++) controller.names[controller.seatAt(position)],
      ],
      winner: pending == null ? null : controller.positionOf(pending.winner),
    );
  }

  @override
  State<_Trick> createState() => _TrickState();
}

class _TrickState extends State<_Trick> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: Pacing.trickSweeps,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() => _taken = const []);
    });

  /// The finished trick on its way to whoever took it: each card and
  /// the slot it is leaving from.
  List<(Card, int)> _taken = const [];
  Offset _towards = Offset.zero;

  /// The position of the card that took the trick: the others are
  /// gathered onto it.
  int _taker = 0;

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_Trick old) {
    super.didUpdateWidget(old);
    final winner = old.winner;
    if (winner == null) return;
    final swept = [
      for (var position = 0; position < seatCount; position++)
        if (old.cards[position] != null && widget.cards[position] == null) (old.cards[position]!, position),
    ];
    // All four going at once is the trick being swept; anything less is
    // the table catching up with itself.
    if (swept.length < seatCount) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    // No setState: this is a widget update, and the build is next.
    // The taker's own card first, so the other three are drawn over it
    // as they are gathered onto it.
    _taken = [
      for (final s in swept)
        if (s.$2 == winner) s,
      for (final s in swept)
        if (s.$2 != winner) s,
    ];
    _towards = seatDirection[winner]!;
    _taker = winner;
    _sweep.forward(from: 0);
  }

  /// Where a slot sits, out from the middle of the trick.
  Offset _at(int position) => Offset(
        widget.offsets[position]!.dx * widget.cardWidth * _stepAcross,
        widget.offsets[position]!.dy * widget.cardHeight * _stepDown,
      );

  @override
  Widget build(BuildContext context) {
    final away = Offset(_towards.dx * widget.size.width * 0.9, _towards.dy * widget.size.height * 0.9);
    return SizedBox.fromSize(
      size: widget.size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          for (var position = 0; position < seatCount; position++)
            Transform.translate(
              offset: _at(position),
              child: _TrickSlot(
                card: widget.cards[position],
                name: widget.names[position],
                order: widget.orders[position],
                width: widget.cardWidth,
                winning: widget.winner == position,
                from: seatDirection[position]!,
              ),
            ),
          for (final (card, position) in _taken)
            AnimatedBuilder(
              animation: _sweep,
              builder: (context, child) {
                final v = _sweep.value;
                // Gathered and taken: the other three are swept onto
                // the card that took the trick, which is the one
                // furthest towards its taker, so every card only ever
                // moves the one way; and the pile is pulled off towards
                // the taker, getting up to speed as it goes. Solid
                // while it is plainly on the felt, and gone by the end.
                final go = Easing.standardAccelerate.transform(v);
                final together = Curves.easeInOutCubic.transform((v / 0.7).clamp(0.0, 1.0));
                final fade = Curves.easeIn.transform(((v - 0.4) / 0.6).clamp(0.0, 1.0));
                final at = _at(position);
                return Transform.translate(
                  offset: Offset.lerp(at, _at(_taker), together)! + away * go,
                  child: Opacity(
                    opacity: 1 - fade,
                    child: Transform.scale(scale: 1 - 0.3 * go, child: child),
                  ),
                );
              },
              child: IgnorePointer(
                child: ExcludeSemantics(child: CardView(card: card, width: widget.cardWidth)),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrickSlot extends StatelessWidget {
  const _TrickSlot({
    required this.card,
    required this.name,
    required this.order,
    required this.width,
    required this.winning,
    required this.from,
  });

  final Card? card;
  final String name;
  final int? order;
  final double width;
  final bool winning;

  /// Which way the seat that plays into this slot lies, so its card
  /// comes in from that side of the screen rather than out of the air.
  final Offset from;

  @override
  Widget build(BuildContext context) {
    // Spoken as "Cyrano led the ace of clubs" / "Juliet played the 5 of
    // clubs": a screen reader hears the trick, and so does anything
    // else that reads the table through the accessibility tree.
    final l10n = context.l10n;
    final label = card == null
        ? null
        : order == 0
            ? l10n.seatLed(name, l10n.cardInSentence(card!))
            : l10n.seatPlayed(name, l10n.cardInSentence(card!));
    return AnimatedSwitcher(
      duration: Pacing.cardLands,
      // What leaves a slot is carried off by the sweep above, so there
      // is nothing here to play backwards.
      reverseDuration: Duration.zero,
      // Eased below, a curve to each part of the landing.
      switchInCurve: Curves.linear,
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final v = animation.value;
          // In fast and settling long, the way a card played onto a
          // table arrives: already solid a third of the way in rather
          // than fading up the whole way like something appearing, and
          // coming down onto the felt — a touch big, a touch askew —
          // as it lands.
          final t = Easing.emphasizedDecelerate.transform(v);
          final solid = Curves.easeOut.transform((v / 0.3).clamp(0.0, 1.0));
          final left = 1 - t;
          return Opacity(
            opacity: solid,
            child: FractionalTranslation(
              translation: from * 1.7 * left,
              child: Transform.rotate(
                angle: 0.07 * (from.dx + from.dy) * left,
                child: Transform.scale(scale: 1 + 0.06 * left, child: child),
              ),
            ),
          );
        },
      ),
      child: card == null
          ? CardGhost(key: const ValueKey('empty'), width: width)
          : Semantics(
              key: ValueKey(card!.code),
              label: label,
              child: ExcludeSemantics(
                child: CardView(
                  card: card!,
                  width: width,
                  highlighted: winning,
                ),
              ),
            ),
    );
  }
}

/// A seat's badge, yours included: who they are, where they stand in
/// the game, what they have taken this hand. Not how many cards they
/// hold — everyone holds as many as you do.
class SeatBadge extends StatelessWidget {
  const SeatBadge({
    super.key,
    required this.seat,
    required this.look,
    required this.game,
    required this.onTurn,
    required this.won,
    required this.maxWidth,
    this.clockMs,
    this.oneLine = false,
    this.height,
    this.onHold,
    required this.iconSize,
    this.position = 0,
  });

  /// Who sits there, as the table draws them: the name, the icon, and
  /// whether a bot plays the seat, which the icon and a screen reader
  /// both say.
  final SeatLook look;

  /// What a long press on the badge offers, if anything.
  final VoidCallback? onHold;

  final int seat;

  /// Where the seat is drawn from the player's: 0 their own, 1 on their
  /// left — the seat that plays after them — 2 across, 3 on their right.
  /// A sighted player reads it off the felt; a screen reader says it.
  final int position;
  final HeartsGame game;
  final bool onTurn;

  final bool won;

  /// What the seat has left on its clock, once it is past its grace;
  /// null while there is nothing to show.
  final int? clockMs;

  /// The room the badge has: a side badge's runs from the felt's edge
  /// to the trick's outer card.
  final double maxWidth;

  /// The badge on one line — icon, name, numbers — rather than stacked.
  /// The seat across the felt and the player's own line have the width
  /// for it; a side badge, whose room is a strip beside the trick,
  /// stacks instead.
  final bool oneLine;

  /// How tall the badge is, and how big its icon: the felt chooses
  /// both, since it is the one that gives up the height. A null height
  /// is the badge's own: a stacked one, which takes the height of the
  /// row it is in (TableView).
  final double? height;
  final double iconSize;

  /// The least a badge is given: a two-word name wrapped, or most of
  /// the roster's one-word names on a line, at 58 points of text.
  static const minWidth = 80.0;

  /// A stacked badge's padding at either side, and the least it gives
  /// way to where its strip is narrower than [minWidth] — a 360-point
  /// phone, upright — so that what is inside keeps the room it has at
  /// [minWidth], and the cards keep the hand's size.
  static const _side = 11.0;
  static const _sideLeast = 7.0;

  /// The narrowest a side badge's strip is let be.
  static const leastWidth = minWidth - 2 * (_side - _sideLeast);

  /// What a badge on one line is, exactly: the felt sizes the trick
  /// from the height the seats leave it, so a badge that grew with its
  /// name or the reader's text size would push the cards off the
  /// bottom. It scales its contents into this instead. A face wants
  /// the room of [line]; where the felt is too short to spare it — a
  /// phone on its side — the badge takes [tightLine] and the smaller
  /// icon that goes with it.
  static const line = 48.0;
  static const tightLine = 30.0;

  /// The icon in a badge of a given height, and in a stacked one of a
  /// given card's height: as big as the box can carry with the name
  /// and the numbers beside or under it.
  static double iconOn(double line) => line - 13;
  static double iconIn(double cardHeight) => (cardHeight * 0.38).clamp(22.0, 40.0);

  /// Every name on the felt is this size, whoever it belongs to.
  static const nameSize = 13.0;
  static const _numberSize = 12.5;


  @override
  Widget build(BuildContext context) {
    final total = game.totals[seat];
    final taken = game.taken[seat];

    // One spoken line per seat: who, where they stand, how many points
    // this hand, whether it is their turn, and their clock once it runs.
    final clock = clockMs;
    return Semantics(
      label: '${context.l10n.seatScores(look.bot ? '${look.name}${context.l10n.seatIsBot}' : look.name, total, taken)}'
          '${onTurn ? context.l10n.seatOnTurn : ''}${clock == null ? '' : context.l10n.seatClock(clockSeconds(clock))}'
          '${position == 0 ? '' : context.l10n.seatWhere(switch (position) { 1 => 'left', 2 => 'across', _ => 'right' })}',
      onLongPress: onHold,
      child: ExcludeSemantics(
        child: height == null ? _held(context, total, taken) : SizedBox(height: height, child: _held(context, total, taken)),
      ),
    );
  }

  /// The badge, and a long press on it where there is one to make.
  Widget _held(BuildContext context, int total, int taken) {
    final badge = _badge(context, total, taken);
    if (onHold == null) return badge;
    return GestureDetector(behavior: HitTestBehavior.opaque, onLongPress: onHold, child: badge);
  }

  /// The room the name has: the badge's, less its padding, its border
  /// at its widest — the gold one on the seat whose turn it is — and,
  /// on one line, the icon beside it. At ordinary type; the name's own
  /// room grows with the reader's (below).
  double get nameRoom => maxWidth - _padding.horizontal - 2 * _borderMost - (oneLine ? iconSize + 6 : 0);

  EdgeInsets get _padding => oneLine
      ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
      : EdgeInsets.symmetric(horizontal: ((maxWidth - (minWidth - 2 * _side)) / 2).clamp(_sideLeast, _side), vertical: 7);

  /// The border's width on the seat whose turn it is, or that just took
  /// the trick; a point otherwise.
  static const _borderMost = 1.6;

  /// The name, in the room it has, at one size wherever it is: every
  /// player's name is the same size as every other's, so a long one is
  /// not a smaller one. On one line when it fits; wrapped at its
  /// spaces where the badge is stacked and the name has any — Mumtaz
  /// Mahal in the east seat of a phone; and cut with an ellipsis when
  /// even that will not go in.
  ///
  /// At the reader's own text size the name is laid out as it is at
  /// ordinary type, only bigger — the room grows with the type — and
  /// the badge draws it as large as its box allows (below): never cut
  /// shorter than at ordinary type, and never drawn smaller than it.
  /// Cyrano is Cyrano at twice the type on the smallest phone, not
  /// "Cy…".
  Widget _name(BuildContext context, double room) {
    final style = TextStyle(
      fontSize: nameSize,
      fontWeight: FontWeight.w600,
      color: onTurn ? Palette.gold : Palette.chrome,
    );
    final scaler = MediaQuery.textScalerOf(context);
    room *= math.max(1.0, scaler.scale(nameSize) / nameSize);
    double widthOf(String text) => (TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout())
        .width;
    final name = look.name;
    final words = name.split(' ');
    final wrapped = !oneLine && words.length > 1;
    if (widthOf(name) <= room) {
      final line = Text(name, style: style, maxLines: 1);
      // A stacked badge keeps room for a second line whether this name
      // needs one or not, so the pair at the sides are one size and a
      // long name is not a smaller name.
      return oneLine ? line : SizedBox(height: 2 * _lineHeight(context, style), child: Center(child: line));
    }
    // Bounded, so the line has something to cut against: the badge
    // scales its contents into its box (below), and unbounded text
    // would be scaled rather than cut.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: room, minHeight: oneLine ? 0 : 2 * _lineHeight(context, style)),
      child: Text(
        name,
        style: style,
        textAlign: TextAlign.center,
        softWrap: wrapped,
        maxLines: wrapped ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        // As wide as its longest line, not as the room: the badge hugs
        // the name.
        textWidthBasis: TextWidthBasis.longestLine,
      ),
    );
  }

  /// One line of the name, as this reader's text size draws it.
  static double _lineHeight(BuildContext context, TextStyle style) => (TextPainter(
        text: TextSpan(text: 'M', style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout())
      .height;

  Widget _badge(BuildContext context, int total, int taken) {
    // The icon sits beside the name where the badge has the width for
    // it and above it where it does not, so a side badge keeps its room
    // for the name either way.
    final icon = SeatIcon(look: look, size: iconSize);
    // Inside the padding and the border at its widest: a name given the
    // room the border takes comes out wider than the badge, and the
    // badge scales it to fit.
    final nameText = _name(context, nameRoom);
    // A three-digit total beside a two-digit hand is the widest this
    // gets, and it is a hair inside a side badge's room: scaled down
    // rather than clipped should a font run wider.
    final numbers = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('$total',
              style: TextStyle(
                  fontSize: _numberSize,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: Palette.chrome.withValues(alpha: 0.85))),
          if (taken > 0) ...[
            const SizedBox(width: 7),
            Pip(
                suit: Suit.hearts,
                size: 10,
                color: Palette.danger.withValues(alpha: 0.9)),
            const SizedBox(width: 3),
            Text('$taken',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Palette.danger.withValues(alpha: 0.95))),
          ],
          if (clockMs != null) ...[
            const SizedBox(width: 8),
            ClockText(ms: clockMs!),
          ],
        ],
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: _padding,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: onTurn ? 0.42 : 0.24),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            // Gold for the seat it is the turn of; white for the seat
            // that just took the trick, which is the same news the pill
            // carries and had better not disagree with it.
            color: onTurn ? Palette.gold : (won ? Palette.chrome : Colors.white.withValues(alpha: 0.10)),
            width: onTurn || won ? _borderMost : 1,
          ),
        ),
        // Scaled into the box rather than overflowing it: a badge is
        // given its size by the felt — the height of the card beside
        // it, or one line — and a name that wraps to two is a hair more
        // than that, and a reader who has turned the text up can be a
        // good deal more. A badge is a label on the felt, and grows
        // with the reader's type as far as the felt has room for it.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: oneLine
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [icon, const SizedBox(width: 6), nameText, const SizedBox(width: 8), numbers],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [icon, const SizedBox(height: 4), nameText, const SizedBox(height: 3), numbers],
                ),
        ),
      ),
    );
  }
}

/// Says [message] aloud to a screen reader when it appears and when it
/// changes, and draws [child]: what the felt shows for a moment — who
/// took the trick, that it is your turn — is gone before anyone could
/// find it by moving through the screen, so it is said as it happens.
class Announced extends StatefulWidget {
  const Announced({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<Announced> createState() => _AnnouncedState();
}

class _AnnouncedState extends State<Announced> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _say());
  }

  @override
  void didUpdateWidget(Announced old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) _say();
  }

  void _say() {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), widget.message, Directionality.of(context));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The line in the felt's top corner (TableView.corner): small, quiet,
/// and at the reader's text size, wrapped where it must be.
class FeltCorner extends StatelessWidget {
  const FeltCorner({super.key, required this.text, required this.tone});

  final String text;
  final Color tone;

  static const _padding = EdgeInsets.symmetric(horizontal: 9, vertical: 4);
  static const _type = TextStyle(fontSize: 10.5);

  /// How big the line is in [room], at the reader's text size.
  static Size sizeOf(BuildContext context, String text, double room) {
    final laid = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(_type)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: room - _padding.horizontal);
    return Size(laid.width + _padding.horizontal, laid.height + _padding.vertical);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: _padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: _type.copyWith(color: tone)),
    );
  }
}

/// What [said] says of [name], in [lines] lines [width] wide at the
/// reader's text size: all of it where it fits, and otherwise with the
/// name cut short, a letter at a time, until it does. The name gives
/// way before the sentence round it, as a long name does everywhere on
/// the table, and the sentence is said whole to a screen reader.
String nameGivesWay(BuildContext context,
    {required String Function(String name) said, required String name, required TextStyle style, required double width, int lines = 1}) {
  final type = DefaultTextStyle.of(context).style.merge(style);
  bool fits(String text) => !(TextPainter(
        text: TextSpan(text: text, style: type),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: lines,
      )..layout(maxWidth: width))
          .didExceedMaxLines;
  var line = said(name);
  if (!width.isFinite || fits(line)) return line;
  final letters = name.characters.toList();
  for (var n = letters.length - 1; n > 0; n--) {
    line = said('${letters.take(n).join().trimRight()}…');
    if (fits(line)) return line;
  }
  return line;
}

/// The line the table says, in the slot the felt keeps for it: on one
/// line at the reader's text size, a long name in it giving way first
/// (see [_TrickResult]). Only where the slot is shorter than that type
/// — a felt with no height to spare — is the line drawn smaller to fit
/// it, as a badge draws its own name into its row; and small enough
/// that the turn's pill is still in it at the top of its breath.
class _Said extends StatelessWidget {
  const _Said({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, room) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: room.maxWidth / (1 + _breathing), maxHeight: room.maxHeight / (1 + _breathing)),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room.maxWidth / (1 + _breathing)),
            child: DefaultTextStyle.merge(maxLines: 1, softWrap: false, child: child),
          ),
        ),
      ),
    );
  }
}

class _TrickResult extends StatelessWidget {
  const _TrickResult({required this.you, required this.name, required this.points});

  final bool you;
  final String name;
  final int points;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String who(String name) => you ? l10n.youTakeIt : l10n.takesIt(name);
    String said(String name) => points == 0 ? who(name) : '${who(name)}  ·  $points';
    return Announced(
      message: points == 0 ? who(name) : l10n.takesPoints(who(name), points),
      // Said whole to a screen reader; on the felt, a name too long for
      // the line is cut short, and the sentence and the points kept.
      child: LayoutBuilder(
        builder: (context, room) => _Pill(
          text: _Pill.fit(context, room.maxWidth, said, name),
          // A trick that has been taken is news, not a turn to take:
          // gold is kept for the seat it is the turn of (theme.dart).
          tone: points == 0 ? Palette.chrome : Palette.danger,
        ),
      ),
    );
  }
}

class _TurnHint extends StatelessWidget {
  const _TurnHint({required this.game, required this.mySeat});

  final HeartsGame game;
  final int mySeat;

  @override
  Widget build(BuildContext context) {
    final seat = game.currentSeat;
    if (seat == null) return const SizedBox.shrink();
    // "Your turn" whether leading or following: "your lead" reads as
    // a standing in the game, and in Hearts leading is no prize.
    if (seat == mySeat) return Announced(message: context.l10n.yourTurn, child: _YourTurn(text: context.l10n.yourTurn));
    return const SizedBox.shrink();
  }
}

/// The pill that says it is your turn, glowing and breathing gold so it
/// is seen from across the room — a turn waited on is a table waiting.
/// Held still, glow and all, for a reader who has asked for less
/// movement.
class _YourTurn extends StatefulWidget {
  const _YourTurn({required this.text});

  final String text;

  @override
  State<_YourTurn> createState() => _YourTurnState();
}

class _YourTurnState extends State<_YourTurn> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!turnPillBreathes || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _breath
        ..stop()
        ..value = 0.6;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_breath.value);
        return Transform.scale(
          scale: 1 + _breathing * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Palette.gold.withValues(alpha: 0.25 + 0.45 * t), blurRadius: 10 + 14 * t, spreadRadius: 1 + 3 * t),
              ],
            ),
            child: child,
          ),
        );
      },
      child: _Pill(text: widget.text, tone: Palette.gold, strong: true),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.tone, this.strong = false});

  final String text;
  final Color tone;

  /// Filled with its tone rather than outlined: the one pill that asks
  /// for something.
  final bool strong;

  static const _padding = EdgeInsets.symmetric(horizontal: 13, vertical: 6);
  static const _type = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.2);

  static TextPainter _laid(BuildContext context, String text, TextScaler scaler) => TextPainter(
        text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(_type)),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();

  /// How much taller the reader's text size makes a pill than ordinary
  /// type does: the felt's row for it grows by as much.
  static double growth(BuildContext context) =>
      _laid(context, 'M', MediaQuery.textScalerOf(context)).height - _laid(context, 'M', TextScaler.noScaling).height;

  /// What [said] says of [name] on one line of a pill in [room].
  static String fit(BuildContext context, double room, String Function(String name) said, String name) =>
      nameGivesWay(context, said: said, name: name, style: _type, width: room - _padding.horizontal - 2);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: _padding,
      decoration: BoxDecoration(
        color: strong ? tone : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withValues(alpha: strong ? 1 : 0.5)),
      ),
      // Drawn smaller where even a name cut to its first letter leaves
      // the line too long for its room, as it is where the row is too
      // short for it (_Said): a felt narrowed by a note beside it, at
      // the largest type (ui/table_layout.dart, note).
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          style: _type.copyWith(
            fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
            color: strong ? Felt.dark : tone,
          ),
        ),
      ),
    );
  }
}

/// A clock's seconds, rounded up: "0 s" only once it has run out.
int clockSeconds(int ms) => (ms / 1000).ceil();

/// A badge laid out for its size alone: it takes up its room and is not
/// drawn, heard or touched. The two of a pair are each laid out over a
/// ghost of the other, so they come out one size.
class BadgeGhost extends StatelessWidget {
  const BadgeGhost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: child,
        ),
      );
}

/// A seat's remaining clock, on a badge or the score line: the seconds
/// and a small dial, red, since a running clock is the one thing on
/// the felt that asks for haste.
class ClockText extends StatelessWidget {
  const ClockText({super.key, required this.ms});

  final int ms;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 11, color: Palette.danger.withValues(alpha: 0.95)),
        const SizedBox(width: 2),
        Text('${clockSeconds(ms)} s',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: Palette.danger.withValues(alpha: 0.95))),
      ],
    );
  }
}
