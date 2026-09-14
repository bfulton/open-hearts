/// The felt: opponents around the edge, the trick in the middle.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';
import 'package:engine/engine.dart' as engine;
import '../avatar.dart';
import '../table_model.dart';
import '../theme.dart';
import 'card_view.dart';
import 'pip.dart';
import 'player_icon.dart';

/// The badges' inset from the felt's edge, and the least gap between a
/// side badge and the trick's outer card.
const _badgeInset = 6.0;
const _badgeGap = 8.0;

/// Where each seat's badge sits: pinned to the rail, well clear of the
/// trick. Seat 0 is the player at the bottom and has no badge — the
/// score line under the felt and the hand say everything about them.
/// Play runs 0-1-2-3, which reads clockwise once the seats are laid out
/// this way.
const _badgeAt = <int, Alignment>{
  1: Alignment(-1, -0.18),
  2: Alignment(0, -1),
  3: Alignment(1, -0.18),
};

/// Which way each seat's played card sits from the middle of the trick,
/// in units of the trick card's own size: a diamond where height is
/// spare, flatter and wider where it is not (a landscape phone), so the
/// four cards keep their size in the height the felt has.
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

class TableView extends StatelessWidget {
  const TableView({super.key, required this.controller});

  final TableModel controller;

  @override
  Widget build(BuildContext context) {
    final game = controller.game;
    final pending = game.pendingTrick;

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        // A wide felt — a landscape phone — lays the trick out flatter
        // and its badges on one line, since height is what it lacks.
        final wide = box.width > box.height * 1.3;
        final offsets = wide ? _wideTrickOffset : _trickOffset;
        // The trick has to fit four cards in a diamond AND leave the
        // badges their rail, so it is sized from whichever dimension
        // runs out first rather than from the width alone.
        var cardWidth = [
          box.width * (wide ? 0.16 : 0.21),
          box.height * (wide ? 0.215 : 0.155),
          76.0,
        ].reduce((a, b) => a < b ? a : b).clamp(34.0, 76.0);
        // The side badges' room: from the felt's edge to the trick's
        // outer card, less a gap. A name has to fit it, wrapped if it
        // must; and on a felt too narrow for both, the trick gives way
        // rather than running under the badges.
        final reach = offsets[3]!.dx * 1.15 + 0.5; // the east card's far edge, in card widths from the middle
        double sideRoomFor(double cw) => box.width / 2 - cw * reach - _badgeInset - _badgeGap;
        if (sideRoomFor(cardWidth) < _SeatBadge.minWidth) {
          cardWidth = ((box.width / 2 - _badgeInset - _badgeGap - _SeatBadge.minWidth) / reach).clamp(34.0, cardWidth);
        }
        final sideRoom = sideRoomFor(cardWidth).clamp(_SeatBadge.minWidth, box.width);
        final cardHeight = cardHeightFor(cardWidth);
        final trickBox = wide ? Size(cardWidth * 3.6, cardHeight * 2.3) : Size(cardWidth * 2.9, cardHeight * 2.7);

        Widget badge(int position) => _SeatBadge(
              seat: controller.seatAt(position),
              name: controller.names[controller.seatAt(position)],
              game: game,
              onTurn: game.currentSeat == controller.seatAt(position),
              won: pending?.winner == controller.seatAt(position),
              clockMs: controller.clockMs(controller.seatAt(position)),
              iconSeed: controller.iconSeedOf(controller.seatAt(position)),
              avatar: controller.avatarOf(controller.seatAt(position)),
              compact: wide,
              maxWidth: position == 2 ? box.width - 2 * _badgeInset : sideRoom,
            );

        // The trick, as one centred block. Slots hold their place so
        // arriving cards never shove the layout around.
        final trick = SizedBox.fromSize(
          size: trickBox,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              for (var position = 0; position < seatCount; position++)
                Transform.translate(
                  offset: Offset(
                    offsets[position]!.dx * cardWidth * 1.15,
                    offsets[position]!.dy * cardHeight * 1.02,
                  ),
                  child: _TrickSlot(
                    card: _cardFrom(game, controller.seatAt(position)) ??
                        (position == 0 ? controller.pendingPlay : null),
                    name: controller.names[controller.seatAt(position)],
                    order: _orderOf(game, controller.seatAt(position)) ??
                        (position == 0 && controller.pendingPlay != null ? game.trick.length : null),
                    width: cardWidth,
                    winning: pending != null && pending.winner == controller.seatAt(position),
                  ),
                ),
            ],
          ),
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

        // Portrait: the four seats read as one column. The gap above the
        // trick and the gap below it are the same, so the badge at the
        // top of the felt and the player's own line just under it sit
        // the same distance from the cards; the pill takes the gap
        // below. What is left over is the felt's to give away — the
        // action line floats in it (table_layout.dart).
        if (!wide) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _badgeInset),
            child: Column(
              children: [
                badge(2),
                const Spacer(),
                SizedBox(
                  height: trickBox.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Align(alignment: Alignment.centerLeft, child: badge(1)),
                      Align(alignment: Alignment.centerRight, child: badge(3)),
                      Align(alignment: Alignment.center, child: trick),
                    ],
                  ),
                ),
                Expanded(child: Center(child: pill)),
              ],
            ),
          );
        }

        // Landscape: height is what is scarce, so the badges keep to the
        // rail and the trick lies flat across the middle of the felt.
        return Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _badgeInset),
              child: Stack(
                children: [
                  for (var position = 1; position < seatCount; position++)
                    Align(alignment: _badgeAt[position]!, child: badge(position)),
                ],
              ),
            ),
            Align(alignment: const Alignment(0, 0.04), child: trick),
            Align(alignment: const Alignment(0, 0.88), child: pill),
          ],
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

class _TrickSlot extends StatelessWidget {
  const _TrickSlot({
    required this.card,
    required this.name,
    required this.order,
    required this.width,
    required this.winning,
  });

  final engine.Card? card;
  final String name;
  final int? order;
  final double width;
  final bool winning;

  @override
  Widget build(BuildContext context) {
    // Spoken as "Cyrano led the ace of clubs" / "Juliet played the 5 of
    // clubs": a screen reader hears the trick, and so does anything
    // else that reads the table through the accessibility tree.
    final label = card == null
        ? null
        : order == 0
            ? '$name led the ${card!.spoken}'
            : '$name played the ${card!.spoken}';
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 190),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween(begin: 0.82, end: 1.0).animate(animation), child: child),
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
class _SeatBadge extends StatelessWidget {
  const _SeatBadge({
    required this.seat,
    required this.name,
    required this.game,
    required this.onTurn,
    required this.won,
    required this.maxWidth,
    required this.iconSeed,
    required this.avatar,
    this.clockMs,
    this.compact = false,
  });

  final int seat;
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

  /// One line — name, total, points — where the felt is short.
  final bool compact;

  /// The least a badge is given: a two-word name wrapped, or most of
  /// the roster's one-word names on a line, at 58 points of text.
  static const minWidth = 80.0;

  @override
  Widget build(BuildContext context) {
    final total = game.totals[seat];
    final taken = game.taken[seat];

    // One spoken line per seat: who, where they stand, how many points
    // this hand, whether it is their turn, and their clock once it runs.
    final clock = clockMs;
    return Semantics(
      label: '$name: $total in the game, $taken this hand'
          '${onTurn ? ', on turn' : ''}${clock == null ? '' : ', ${clockSeconds(clock)} s on the clock'}',
      child: ExcludeSemantics(child: _badge(context, total, taken)),
    );
  }

  EdgeInsets get _padding => compact ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4) : const EdgeInsets.symmetric(horizontal: 11, vertical: 7);

  /// The name, in the room it has: on one line when it fits, else — a
  /// long name, Mumtaz Mahal in the east seat of a phone — wrapped at
  /// its spaces, and a single word wider than the room scaled to it.
  Widget _name(BuildContext context, double room) {
    final style = TextStyle(
      fontSize: 13,
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
    if (widthOf(name) <= room) return Text(name, style: style, maxLines: 1);
    final words = name.split(' ');
    if (words.length > 1 && words.every((w) => widthOf(w) <= room)) {
      return Text(
        name,
        style: style,
        textAlign: TextAlign.center,
        maxLines: words.length,
        // As wide as its longest line, not as the room: the badge hugs
        // the name.
        textWidthBasis: TextWidthBasis.longestLine,
      );
    }
    return FittedBox(fit: BoxFit.scaleDown, child: Text(name, style: style, maxLines: 1));
  }

  Widget _badge(BuildContext context, int total, int taken) {
    // The icon sits above the name where the felt is tall and beside
    // it where it is short, so a side badge keeps its room for the
    // name either way.
    final icon = PlayerIcon(name: name, seed: iconSeed, avatar: avatar, size: compact ? 18 : 22);
    final nameText = _name(context, maxWidth - _padding.horizontal - (compact ? 24 : 0));
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
                  fontSize: 12.5,
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
            color: onTurn || won ? Palette.gold : Colors.white.withValues(alpha: 0.10),
            width: onTurn || won ? 1.6 : 1,
          ),
        ),
        child: compact
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [icon, const SizedBox(width: 6), Flexible(child: nameText), const SizedBox(width: 8), numbers],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [icon, const SizedBox(height: 4), nameText, const SizedBox(height: 3), numbers],
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
    final who = you ? 'You take it' : '$name takes it';
    return _Pill(
      text: points == 0 ? who : '$who  ·  $points',
      tone: points == 0 ? Palette.gold : Palette.danger,
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
    if (seat == mySeat) return const _Pill(text: 'Your turn', tone: Palette.gold);
    return const SizedBox.shrink();
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.tone});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: tone,
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
