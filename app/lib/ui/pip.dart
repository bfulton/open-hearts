/// The four suit symbols, drawn as paths.
///
/// Not text. ♠♥♦♣ are absent from Roboto, so a text pip falls through to
/// a network font — which renders an empty box on any network that
/// cannot reach fonts.gstatic.com, and that box is most of the card.
/// Paths render identically everywhere, offline included, and stay crisp
/// at the 12 logical pixels an inline pip gets.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:engine/engine.dart' as engine;
import '../theme.dart';

/// Colour a suit is drawn in on a card face: the usual red pair, the
/// usual black pair.
Color colorOf(engine.Suit suit) => suit.isRed ? Palette.red : Palette.black;

/// Colour a suit is drawn in ON THE FELT, where the card's white ground
/// is missing. Black on dark green is invisible, so the black suits go
/// pale and the red ones lift to stay their equal.
Color colorOnFelt(engine.Suit suit) =>
    suit.isRed ? const Color(0xFFE8776A) : Palette.chrome;

class Pip extends StatelessWidget {
  const Pip({super.key, required this.suit, required this.size, this.color});

  final engine.Suit suit;
  final double size;

  /// Defaults to the suit's own colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _PipPainter(suit, color ?? colorOf(suit)),
      ),
    );
  }
}

class _PipPainter extends CustomPainter {
  const _PipPainter(this.suit, this.color);

  final engine.Suit suit;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = pipPath(suit);
    // The paths are authored in a 100x100 box.
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PipPainter old) =>
      old.suit != suit || old.color != color;
}

/// Works each suit's outline out ahead of the first frame that draws
/// one, a suit at a time, each in a turn of the event loop of its own:
/// the spade and the club are unions of shapes, and on the web the first
/// to draw each works the union out on the page's thread — a frame's
/// worth of work on a slow phone, better done while the page waits for
/// something else (review_page.dart, while a game is fetched).
void warmPips() {
  for (final (i, suit) in engine.Suit.values.indexed) {
    Timer(Duration(milliseconds: i), () => pipPath(suit).getBounds());
  }
}

/// The suit outline in a 100x100 box, centred with a little margin.
Path pipPath(engine.Suit suit) => switch (suit) {
      engine.Suit.hearts => _heart,
      engine.Suit.diamonds => _diamond,
      engine.Suit.spades => _spade,
      engine.Suit.clubs => _club,
    };

final _heart = Path()
  ..moveTo(50, 92)
  ..cubicTo(50, 92, 6, 61, 6, 33)
  ..cubicTo(6, 16, 19, 6, 32, 6)
  ..cubicTo(41, 6, 47, 11, 50, 18)
  ..cubicTo(53, 11, 59, 6, 68, 6)
  ..cubicTo(81, 6, 94, 16, 94, 33)
  ..cubicTo(94, 61, 50, 92, 50, 92)
  ..close();

final _diamond = Path()
  ..moveTo(50, 4)
  ..cubicTo(50, 4, 72, 32, 92, 50)
  ..cubicTo(72, 68, 50, 96, 50, 96)
  ..cubicTo(50, 96, 28, 68, 8, 50)
  ..cubicTo(28, 32, 50, 4, 50, 4)
  ..close();

/// The spade is the heart inverted, with a stem under it.
final _spade = () {
  final body = Path()
    ..moveTo(50, 6)
    ..cubicTo(50, 6, 94, 37, 94, 65)
    ..cubicTo(94, 78, 84, 86, 72, 86)
    ..cubicTo(62, 86, 55, 80, 52, 73)
    ..cubicTo(52, 73, 52, 73, 52, 73)
    ..cubicTo(48, 73, 48, 73, 48, 73)
    ..cubicTo(45, 80, 38, 86, 28, 86)
    ..cubicTo(16, 86, 6, 78, 6, 65)
    ..cubicTo(6, 37, 50, 6, 50, 6)
    ..close();
  return Path.combine(PathOperation.union, body, _stem);
}();

/// Three lobes and the same stem.
final _club = () {
  var p = Path()..addOval(Rect.fromCircle(center: const Offset(50, 27), radius: 21));
  for (final c in const [Offset(25, 62), Offset(75, 62)]) {
    p = Path.combine(
        PathOperation.union, p, Path()..addOval(Rect.fromCircle(center: c, radius: 21)));
  }
  return Path.combine(PathOperation.union, p, _stem);
}();

/// The stem both the spade and the club stand on: a waisted trapezoid
/// that reads as a stalk rather than a wedge.
final _stem = Path()
  ..moveTo(44, 58)
  ..cubicTo(44, 74, 41, 86, 34, 96)
  ..lineTo(66, 96)
  ..cubicTo(59, 86, 56, 74, 56, 58)
  ..close();

/// A card named in running text — "the 2 of clubs" as a rank and a pip
/// rather than a glyph that might not exist.
class CardChip extends StatelessWidget {
  const CardChip({
    super.key,
    required this.card,
    this.size = 13,
    this.color,
    this.onFelt = false,
  });

  final engine.Card card;
  final double size;
  final Color? color;

  /// Drawn straight onto the table rather than on a card face.
  final bool onFelt;

  @override
  Widget build(BuildContext context) {
    final tint =
        color ?? (onFelt ? colorOnFelt(card.suit) : colorOf(card.suit));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          card.rank.label,
          style: TextStyle(
            fontSize: size,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: tint,
          ),
        ),
        const SizedBox(width: 1.5),
        // A chip is a word in a line of text, and its suit is half of
        // it: the pip goes up with the reader's type as the rank does.
        Pip(suit: card.suit, size: MediaQuery.textScalerOf(context).scale(size * 0.82), color: tint),
      ],
    );
  }
}
