/// Card faces and backs, drawn rather than loaded.
///
/// Widgets instead of images: a card has to be legible at 24 logical
/// pixels of exposed sliver on a phone and crisp at four times that on a
/// desktop, and text plus a pip scales to both for free.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';

import '../theme.dart';
import 'pip.dart';

/// Poker proportions. Every size in the UI is a width; height follows.
const cardAspect = 5 / 7;

double cardHeightFor(double width) => width / cardAspect;

class CardView extends StatelessWidget {
  const CardView({
    super.key,
    required this.card,
    required this.width,
    this.dimmed = false,
    this.highlighted = false,
    this.selected = false,
    this.marked = false,
  });

  final engine.Card card;
  final double width;

  /// Not playable right now: greyed, but still tappable so the table can
  /// say why.
  final bool dimmed;

  /// Ringed in gold — the winning card of a finished trick, or the one
  /// forced play in a hand.
  final bool highlighted;

  /// Chosen for the pass.
  final bool selected;

  /// Arrived in the pass this hand — a dot in the corner, quiet enough to
  /// ignore and specific enough to find.
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final height = cardHeightFor(width);
    final color = colorOf(card.suit);
    final radius = width * 0.11;
    // "10" is twice the width of every other rank; shrinking it keeps
    // the corner block the same size on all thirteen cards.
    final rankSize = width * (card.rank.label.length > 1 ? 0.32 : 0.40);

    return Opacity(
      opacity: dimmed ? 0.42 : 1,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Palette.cardFace,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: selected
                ? Palette.gold
                : highlighted
                    ? Palette.gold
                    : Palette.cardEdge.withValues(alpha: 0.35),
            width: selected || highlighted ? width * 0.045 : 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: width * 0.11,
              offset: Offset(0, width * 0.045),
            ),
            if (highlighted)
              BoxShadow(
                color: Palette.gold.withValues(alpha: 0.55),
                blurRadius: width * 0.35,
              ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // The big faint pip, so a card reads as its suit from the
            // corner of the eye even when the rank is covered. Clipped
            // by the card, so it can hang off the corner.
            Positioned(
              right: -width * 0.13,
              bottom: -width * 0.13,
              child: Pip(
                suit: card.suit,
                size: width * 0.76,
                color: color.withValues(alpha: 0.12),
              ),
            ),
            // On the LEFT: in a fan every card but the last shows only
            // its left edge, so a right-corner dot would be invisible on
            // exactly the twelve cards that need it.
            if (marked)
              Positioned(
                bottom: width * 0.09,
                left: width * 0.09,
                child: Container(
                  width: width * 0.15,
                  height: width * 0.15,
                  decoration: const BoxDecoration(
                    color: Palette.gold,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  width * 0.10, width * 0.07, width * 0.06, width * 0.06),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    card.rank.label,
                    // The rank is the card's picture, not a line to
                    // read: drawn at a fraction of the card, as the pip
                    // under it is, and in a fan only the corner the next
                    // card leaves shows it — about a quarter of a card on
                    // a phone, which a 10 already fills. Grown with the
                    // reader's text it would grow under that card and
                    // off this one, so it keeps the card's size, which
                    // is already larger than the type round the table at
                    // twice its size; the card is what the table grows
                    // (ui/scaled.dart), and a screen reader hears its
                    // name in full.
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: rankSize,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -width * 0.02,
                      color: color,
                    ),
                  ),
                  SizedBox(height: width * 0.03),
                  Pip(suit: card.suit, size: width * 0.26, color: color),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A face-down card. Opponent hands are counts, not cards, so this is
/// only ever drawn as a stack.
class CardBack extends StatelessWidget {
  const CardBack({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: cardHeightFor(width),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(width * 0.11),
        border: Border.all(color: Palette.gold.withValues(alpha: 0.35), width: 0.9),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7A1F2B), Color(0xFF4A1119)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: width * 0.09,
            offset: Offset(0, width * 0.03),
          ),
        ],
      ),
      child: Center(
        child: Icon(
          Icons.favorite,
          size: width * 0.42,
          color: Palette.gold.withValues(alpha: 0.30),
        ),
      ),
    );
  }
}

/// The place a card will land: the room it takes, and nothing drawn.
/// The room is what keeps the trick from jumping as cards arrive, and a
/// trick reads as a trick without outlines on the felt.
class CardGhost extends StatelessWidget {
  const CardGhost({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(width: width, height: cardHeightFor(width));
}
