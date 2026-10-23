/// A shower of confetti over the table, once, for a moon the player
/// shot (overlays.dart). Decoration only: nothing in it to read or tap,
/// and nothing at all where the device asks for less motion.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// How long the shower lasts, from the first piece falling to the last
/// gone.
const confettiFalls = Duration(milliseconds: 2800);

/// How many pieces fall.
const confettiPieces = 110;

class Confetti extends StatefulWidget {
  const Confetti({super.key, this.seed = 0});

  /// Where the pieces start and how they fall, so that a screenshot or
  /// a test sees the same shower each time.
  final int seed;

  @override
  State<Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<Confetti> with SingleTickerProviderStateMixin {
  late final AnimationController _fall = AnimationController(vsync: this, duration: confettiFalls);
  late final List<_Piece> _pieces = () {
    final r = math.Random(widget.seed);
    return List.generate(confettiPieces, (_) => _Piece(r));
  }();

  bool get _still => MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Once, and not where the device asks for less motion.
    if (!_still && _fall.status == AnimationStatus.dismissed) _fall.forward();
  }

  @override
  void dispose() {
    _fall.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_still) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(painter: _Shower(_pieces, _fall), size: Size.infinite),
        ),
      ),
    );
  }
}

/// One piece: where it starts, how it falls, turns and flutters, as
/// shares of the space it falls through and of the shower's time.
class _Piece {
  _Piece(math.Random r)
      : x = r.nextDouble(),
        start = r.nextDouble() * 0.3,
        speed = 0.85 + r.nextDouble() * 0.5,
        drift = (r.nextDouble() - 0.5) * 0.25,
        flutter = r.nextDouble() * math.pi * 2,
        spin = (r.nextDouble() - 0.5) * 16,
        length = 6 + r.nextDouble() * 6,
        round = r.nextInt(5) == 0,
        color = _colors[r.nextInt(_colors.length)];

  /// The table's own: gold, a heart's red, a card's face, a win's green.
  static const _colors = [Palette.gold, Palette.red, Palette.cardFace, Palette.win];

  final double x;
  final double start;
  final double speed;
  final double drift;
  final double flutter;
  final double spin;
  final double length;
  final bool round;
  final Color color;
}

class _Shower extends CustomPainter {
  _Shower(this.pieces, this.fall) : super(repaint: fall);

  final List<_Piece> pieces;
  final Animation<double> fall;

  @override
  void paint(Canvas canvas, Size size) {
    final t = fall.value;
    if (t == 0 || t == 1) return;
    // Gone over the last quarter, wherever each piece has got to.
    final fade = t < 0.75 ? 1.0 : 1 - (t - 0.75) / 0.25;
    final paint = Paint();
    for (final p in pieces) {
      final s = ((t - p.start) / (1 - p.start)).clamp(0.0, 1.0);
      if (s == 0) continue;
      // Falling faster as it goes, from just above the top to below
      // the bottom, drifting and fluttering side to side.
      final y = size.height * (-0.05 + 1.2 * p.speed * s * (0.4 + 0.6 * s));
      final x = size.width * (p.x + p.drift * s) + math.sin(p.flutter + s * math.pi * 6) * 10;
      paint.color = p.color.withValues(alpha: fade);
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(p.spin * s)
        // Turning over as it falls: its face narrows and widens.
        ..scale(math.cos(p.flutter + s * math.pi * 4), 1);
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.length * 0.35, paint);
      } else {
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.length, height: p.length * 0.4), paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Shower old) => old.pieces != pieces || old.fall != fall;
}
