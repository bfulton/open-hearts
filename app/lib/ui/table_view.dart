/// The felt: opponents around the edge, the trick in the middle.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:engine/engine.dart';
import 'package:engine/engine.dart' as engine;
import '../avatar.dart';
import '../table_model.dart';
import '../theme.dart';
import 'card_view.dart';
import 'pip.dart';
import 'player_icon.dart';
import 'scaled.dart';
import '../l10n/l10n.dart';

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

/// Play runs 0-1-2-3, which reads clockwise once the seats are laid
/// out around the felt: the player at the near edge, then west, north
/// and east. Every seat wears a badge, the player's own included.
/// Which way each seat's played card sits from the middle of the trick,
/// in units of the trick card's own size: a diamond where height is
/// spare, flatter and wider where it is not (a landscape phone), so the
/// four cards keep their size in the height the felt has.
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

const _trickOffset = <int, Offset>{
  0: Offset(0, 0.78),
  1: Offset(-0.86, 0),
  2: Offset(0, -0.78),
  3: Offset(0.86, 0),
};
const _wideTrickOffset = <int, Offset>{
  0: Offset(0, 0.62),
  1: Offset(-1.12, 0),
  2: Offset(0, -0.62),
  3: Offset(1.12, 0),
};

/// Whether the "your turn" pill breathes. A test that waits for the
/// table to come to rest turns it off, since a breath is a frame every
/// sixteen milliseconds for as long as the turn is yours
/// (test/flutter_test_config.dart); one test turns it back on to watch
/// it breathe.
@visibleForTesting
bool turnPillBreathes = true;

class TableView extends StatelessWidget {
  const TableView({super.key, required this.controller, this.onHold});

  final TableModel controller;

  /// Holding a seat's badge, where the page has something to offer
  /// about that player — at a live table, what to do about their
  /// picture. Null leaves the badge alone.
  final void Function(int seat)? onHold;

  @override
  Widget build(BuildContext context) {
    final game = controller.game;
    final pending = game.pendingTrick;

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        // How much bigger than a phone's this table is drawn: its
        // layout's, or on a felt of its own, the felt's.
        final scale = TableScale.maybeOf(context) ?? TableScale.forFelt(box);
        final edge = _badgeInset * scale;
        final badgeGap = _badgeGap * scale;
        final pillRow = _pillRow * scale;
        // A wide felt — a landscape phone — lays the trick out flatter
        // and its badges on one line, since height is what it lacks.
        final wide = box.width > box.height * 1.3;
        final offsets = wide ? _wideTrickOffset : _trickOffset;
        // The badges hold to their cards, so it is the trick that gives
        // way, never the layout that overflows: the two facing badges
        // and their gaps — and in portrait the row kept for the line
        // under the table — come off the height before the trick is
        // sized, and it takes what is left of whichever dimension runs
        // out first.
        // Portrait keeps room under the near badge for the line the
        // table says, and as much again, so the line sits in the middle
        // of it rather than against the badge. And a badge is as tall
        // as a face wants unless that would leave the cards under what
        // a card can be read at, where it takes the smaller size back.
        double cardsUnder(double line) =>
            (box.height - 2 * (line + badgeGap) - (wide ? 0.0 : 2 * pillRow)) / ((wide ? 2.3 : 2.7) / cardAspect);
        final line = (cardsUnder(SeatBadge.line * scale) >= 34.0 ? SeatBadge.line : SeatBadge.tightLine) * scale;
        // The biggest a card is allowed to be, from the felt's own
        // size. A phone is held at arm's length and its felt is small,
        // so seventy-six points is the whole of what fits; a tablet's
        // felt is further away and has room, and cards that stayed a
        // phone's size on it would be a phone's game with green around
        // it (docs/05-form-factors.md). That is the table's scale, the
        // one its type is drawn at too.
        final most = TableScale.phoneCard * scale;
        var cardWidth = [
          box.width * (wide ? 0.16 : 0.21),
          cardsUnder(line),
          most,
        ].reduce((a, b) => a < b ? a : b).clamp(34.0, most);
        // The side badges' room: from the felt's edge to the trick's
        // outer card, less a gap. A name has to fit it, wrapped if it
        // must; and on a felt too narrow for both, the trick gives way
        // rather than running under the badges.
        final reach = offsets[3]!.dx * 1.15 + 0.5; // the east card's far edge, in card widths from the middle
        double sideRoomFor(double cw) => box.width / 2 - cw * reach - edge - badgeGap;
        final leastRoom = SeatBadge.minWidth * scale;
        if (sideRoomFor(cardWidth) < leastRoom) {
          cardWidth = ((box.width / 2 - edge - badgeGap - leastRoom) / reach).clamp(34.0, cardWidth);
        }
        final sideRoom = sideRoomFor(cardWidth).clamp(leastRoom, box.width);
        final cardHeight = cardHeightFor(cardWidth);
        final trickBox = wide ? Size(cardWidth * 3.6, cardHeight * 2.3) : Size(cardWidth * 2.9, cardHeight * 2.7);

        // A badge hugs what it says, up to the room it has: the width
        // of the trick's own column for the seat across the felt and
        // your own, and the strip between a card and the felt's edge
        // for the two at the sides.
        final facing = trickBox.width;

        // A badge is laid out at a phone's scale and drawn at the
        // table's, so the room it is given here is in a phone's points.
        Widget badge(int position) => SeatBadge(
              onHold: onHold == null ? null : () => onHold!(controller.seatAt(position)),
              seat: controller.seatAt(position),
              position: position,
              name: controller.names[controller.seatAt(position)],
              game: game,
              onTurn: game.currentSeat == controller.seatAt(position),
              won: pending?.winner == controller.seatAt(position),
              clockMs: controller.clockMs(controller.seatAt(position)),
              iconSeed: controller.iconSeedOf(controller.seatAt(position)),
              avatar: controller.avatarOf(controller.seatAt(position)),
              // The seat across the felt reads the same way as the
              // player's own line at the near edge: one line, icon
              // first. The side badges have a strip, so they stack.
              oneLine: wide || position.isEven,
              maxWidth: (!wide && position.isEven ? facing : sideRoom) / scale,
              // A stacked badge takes the height of the row it is in,
              // which is the taller of the pair's (below).
              height: wide || position.isEven ? line / scale : null,
              iconSize: wide || position.isEven ? SeatBadge.iconOn(line / scale) : SeatBadge.iconIn(cardHeight / scale),
            );

        // The trick, as one centred block. Slots hold their place so
        // arriving cards never shove the layout around.
        final trick = _Trick(
          size: trickBox,
          offsets: offsets,
          cardWidth: cardWidth,
          cardHeight: cardHeight,
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

        // Under the trick, never across it: who took it, or whose turn
        // it is.
        final Widget pill = pending != null
            ? _TrickResult(
                you: pending.winner == controller.mySeat,
                name: controller.names[pending.winner],
                points: pointsIn(pending.plays.map((p) => p.card)),
              )
            : game.phase == Phase.playing && controller.pendingPlay == null
                ? _TurnHint(game: game, mySeat: controller.mySeat)
                : const SizedBox.shrink();

        // All four seats are on the felt, each badge the same gap from
        // the card it labels, so every badge reads as that card's
        // label. The trick's block is a little deeper than the cards in
        // it, which the gaps above and below take off. What is left
        // over is the rail: in portrait it goes to the far end, above
        // the seat across the table, because the band under the felt
        // already floats the action line (table_layout.dart); on a wide
        // felt, where the action line sits on a row of its own, it is
        // split evenly and the table rides in the middle.
        final inset = trickBox.height / 2 - (offsets[2]!.dy.abs() * cardHeight * 1.02 + cardHeight / 2);
        final gap = (badgeGap - inset).clamp(0.0, badgeGap);
        // Where a side badge's inner edge falls: a gap out from the far
        // edge of the card beside it, measured from the middle of the
        // felt.
        final sideOut = (box.width - 2 * edge) / 2 + cardWidth * reach + badgeGap;
        // Each badge hugs its name, so the two of a pair are each laid
        // out over a ghost of the other, which takes up its room and
        // draws nothing: whichever name is the longer, the pair come out
        // one size.
        Widget ghost(int position) => BadgeGhost(child: badge(position));

        Widget seat(int position) {
          final pair = Stack(
            children: [
              // The two ghosts make the box; the badge fills it.
              ghost(position),
              ghost((position + 2) % seatCount),
              Positioned.fill(child: badge(position)),
            ],
          );
          // A side badge is anchored by its inner edge, a gap out from
          // its card (below), and runs out towards the felt's edge as
          // far as its name takes it.
          return Scaled(
            scale: scale,
            child: wide || position.isEven ? SizedBox(height: line / scale, child: pair) : pair,
          );
        }

        // Where the table sits in the felt. A phone's felt is the size
        // of its table and the slack is a few points either way, so it
        // is centred and that is that. A tablet's has height the cards
        // will never grow into, and there the table sits low: the room
        // beyond the far seat reads as the far end of the table, while
        // the room under your own badge is the gap between you and your
        // own cards, and wants to be small.
        final cluster = 2 * line + 2 * gap + trickBox.height + (wide ? 0.0 : 2 * pillRow);
        final slack = (box.height - cluster).clamp(0.0, double.infinity);
        final above = slack > _roomToSpare ? slack * 0.7 : slack / 2;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: edge),
          child: Column(
            children: [
              SizedBox(height: above),
              seat(2),
              SizedBox(height: gap),
              SizedBox(
                height: trickBox.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Positioned(right: sideOut, top: 0, bottom: 0, child: Center(child: seat(1))),
                    Positioned(left: sideOut, top: 0, bottom: 0, child: Center(child: seat(3))),
                    Align(alignment: Alignment.center, child: trick),
                  ],
                ),
              ),
              SizedBox(height: gap),
              if (wide)
                // The line beside the badge, with the same room kept on
                // the other side of it, so the badge holds the middle
                // whether or not there is anything to say.
                SizedBox(
                  height: line,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Expanded(child: SizedBox.shrink()),
                      seat(0),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Scaled(
                            scale: scale,
                            child: Padding(padding: const EdgeInsets.only(left: 12), child: pill),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                seat(0),
                // The room under the near seat, with the line the table
                // says in the middle of it: the action line has the row
                // against the hand (table_layout.dart).
                Expanded(child: Center(child: Scaled(scale: scale, child: pill))),
              ],
              if (wide) const Spacer(),
            ],
          ),
        );
      },
    );
  }

  engine.Card? _cardFrom(HeartsGame game, int seat) {
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
  final List<engine.Card?> cards;
  final List<int?> orders;
  final List<String> names;

  /// The position that has taken the finished trick, while it is still
  /// on the table; null at every other moment.
  final int? winner;

  @override
  State<_Trick> createState() => _TrickState();
}

class _TrickState extends State<_Trick> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() => _taken = const []);
    });

  /// The finished trick on its way to whoever took it: each card and
  /// the slot it is leaving from.
  List<(engine.Card, int)> _taken = const [];
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
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return;
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
        widget.offsets[position]!.dx * widget.cardWidth * 1.15,
        widget.offsets[position]!.dy * widget.cardHeight * 1.02,
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

  final engine.Card? card;
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
      duration: const Duration(milliseconds: 240),
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

/// An opponent: who they are, where they stand in the game, what they
/// have taken this hand. Not how many cards they hold — everyone holds
/// as many as you do.
class SeatBadge extends StatelessWidget {
  const SeatBadge({
    super.key,
    required this.seat,
    required this.name,
    required this.game,
    required this.onTurn,
    required this.won,
    required this.maxWidth,
    required this.iconSeed,
    required this.avatar,
    this.clockMs,
    this.oneLine = false,
    this.height,
    this.onHold,
    required this.iconSize,
    this.position = 0,
  });

  /// What a long press on the badge offers, if anything.
  final VoidCallback? onHold;

  final int seat;

  /// Where the seat is drawn from the player's: 0 their own, 1 on their
  /// left — the seat that plays after them — 2 across, 3 on their right.
  /// A sighted player reads it off the felt; a screen reader says it.
  final int position;
  final String name;

  /// What the seat's icon is coloured from.
  final String iconSeed;

  /// How the seat chose to look.
  final Avatar avatar;
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
  /// is the badge's own, which is what [stackedHeight] predicts.
  final double? height;
  final double iconSize;

  /// The least a badge is given: a two-word name wrapped, or most of
  /// the roster's one-word names on a line, at 58 points of text.
  static const minWidth = 80.0;

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

  static const _stacked = EdgeInsets.symmetric(horizontal: 11, vertical: 7);

  @override
  Widget build(BuildContext context) {
    final total = game.totals[seat];
    final taken = game.taken[seat];

    // One spoken line per seat: who, where they stand, how many points
    // this hand, whether it is their turn, and their clock once it runs.
    final clock = clockMs;
    return Semantics(
      label: '${context.l10n.seatScores(name, total, taken)}'
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

  EdgeInsets get _padding => oneLine ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4) : _stacked;

  /// The name, in the room it has, at one size wherever it is: every
  /// player's name is the same size as every other's, so a long one is
  /// not a smaller one. On one line when it fits; wrapped at its
  /// spaces where the badge is stacked and the name has any — Mumtaz
  /// Mahal in the east seat of a phone; and cut with an ellipsis when
  /// even that will not go in.
  Widget _name(BuildContext context, double room) {
    final style = TextStyle(
      fontSize: nameSize,
      fontWeight: FontWeight.w600,
      color: onTurn ? Palette.gold : Palette.chrome,
    );
    final scaler = MediaQuery.textScalerOf(context);
    double widthOf(String text) => (TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout())
        .width;
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
    final icon = PlayerIcon(name: name, seed: iconSeed, avatar: avatar, size: iconSize);
    final nameText = _name(context, maxWidth - _padding.horizontal - (oneLine ? iconSize + 6 : 0));
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
                suit: engine.Suit.hearts,
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
            width: onTurn || won ? 1.6 : 1,
          ),
        ),
        // Scaled into the box rather than overflowing it: a badge is
        // given its size by the felt — the height of the card beside
        // it, or one line — and a name that wraps to two, or a reader
        // who has turned the text up, is a hair more than that.
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

class _TrickResult extends StatelessWidget {
  const _TrickResult({required this.you, required this.name, required this.points});

  final bool you;
  final String name;
  final int points;

  @override
  Widget build(BuildContext context) {
    final who = you ? context.l10n.youTakeIt : context.l10n.takesIt(name);
    return Announced(
      message: points == 0 ? who : context.l10n.takesPoints(who, points),
      child: _Pill(
        text: points == 0 ? who : '$who  ·  $points',
        // A trick that has been taken is news, not a turn to take: gold
        // is kept for the seat it is the turn of (theme.dart).
        tone: points == 0 ? Palette.chrome : Palette.danger,
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
    if (!turnPillBreathes || (MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
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
          scale: 1 + 0.06 * t,
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: strong ? tone : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withValues(alpha: strong ? 1 : 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
          letterSpacing: 0.2,
          color: strong ? Felt.dark : tone,
        ),
      ),
    );
  }
}

/// A clock's seconds, rounded up: "0 s" only once it has run out.
int clockSeconds(int ms) => (ms / 1000).ceil();

/// A seat's remaining clock, on a badge or the score line: the seconds
/// and a small dial, red, since a running clock is the one thing on
/// the felt that asks for haste.
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
