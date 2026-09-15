/// The heart at the front door, folded away and opened out again.
///
/// A sheet of paper folded in half three times and then not there at
/// all, which is the trick: each fold leaves half of what it had, the
/// folded flap lying over what it came from a shade darker, so the
/// whole thing reads as paper rather than as a picture being squashed.
/// Then it comes back out the way it went in.
///
/// The fold itself is the old flat cheat — the flap keeps its far edge
/// on the crease and loses its width as the cosine of how far over it
/// has come — which is what a fold looks like from straight on, and
/// straight on is where the door is looked at from.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Where a fold's crease lies and which way the flap goes over.
enum _Crease { vertical, horizontal }

class FoldingHeart extends StatefulWidget {
  const FoldingHeart({super.key, required this.size, required this.color, this.period = const Duration(seconds: 9), this.at});

  final double size;
  final Color color;

  /// One turn of folding away and opening out.
  final Duration period;

  /// Held at this point of the turn rather than turning, for a still
  /// picture of it — a screenshot, or a test reading one frame.
  final double? at;

  @override
  State<FoldingHeart> createState() => _FoldingHeartState();
}

class _FoldingHeartState extends State<FoldingHeart> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A reader who has asked for less movement gets the heart whole and
    // still; there is nothing in the folding they would be missing.
    final held = widget.at ?? (MediaQuery.disableAnimationsOf(context) ? 0.0 : null);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: held != null
            ? CustomPaint(painter: _FoldedHeart(at: held, color: widget.color))
            : AnimatedBuilder(
                animation: _turn,
                builder: (_, _) => CustomPaint(painter: _FoldedHeart(at: _turn.value, color: widget.color)),
              ),
      ),
    );
  }
}

/// The heart, in the state the turn is at.
///
/// The turn is: a beat whole, three folds, a beat gone, and the same
/// read backwards. A fold keeps the flap's far edge on the crease and
/// takes its width down as the cosine of how far over it has come,
/// which is what a fold looks like from straight on — and straight on
/// is where a front door is looked at from.
class _FoldedHeart extends CustomPainter {
  _FoldedHeart({required this.at, required this.color});

  /// Where the turn is, from 0 to 1.
  final double at;
  final Color color;

  /// The three folds, in the order they are made.
  static const _folds = [_Crease.vertical, _Crease.horizontal, _Crease.vertical];

  /// What the turn is spent on, in order: still, three folds, gone.
  static const _still = 0.14;
  static const _foldFor = 0.09;
  static const _gone = 0.05;

  @override
  void paint(Canvas canvas, Size size) {
    // The same shape going in and coming out: the second half of the
    // turn is the first half backwards.
    final half = _still + _folds.length * _foldFor + _gone;
    final t = (at < 0.5 ? at : 1 - at) / 0.5 * half;
    var made = 0;
    var making = 0.0;
    var shut = 0.0;
    if (t > _still) {
      final into = t - _still;
      made = (into / _foldFor).floor().clamp(0, _folds.length);
      making = made < _folds.length ? (into - made * _foldFor) / _foldFor : 1;
      if (made >= _folds.length) shut = ((into - _folds.length * _foldFor) / _gone).clamp(0.0, 1.0);
    }
    canvas.save();
    if (shut > 0) {
      // Gone: what is left closes about its own middle.
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(1 - shut);
      canvas.translate(-size.width / 2, -size.height / 2);
    }
    _sheet(canvas, Offset.zero & size, 0, 0, made, Curves.easeInOut.transform(making.clamp(0.0, 1.0)), size);
    canvas.restore();
  }

  /// Draws the paper in [sheet]: what the folds from [depth] on have
  /// done to it, at [layers] thicknesses of paper deep.
  void _sheet(Canvas canvas, Rect sheet, int depth, int layers, int made, double making, Size whole) {
    final over = depth >= _folds.length || depth > made
        ? 0.0
        : depth < made
            ? 1.0
            : making;
    if (over <= 0) return _heart(canvas, sheet, layers, whole);

    final crease = _folds[depth];
    final down = crease == _Crease.vertical;
    final stays = down
        ? Rect.fromLTRB(sheet.left, sheet.top, sheet.center.dx, sheet.bottom)
        : Rect.fromLTRB(sheet.left, sheet.top, sheet.right, sheet.center.dy);
    final goes = down
        ? Rect.fromLTRB(sheet.center.dx, sheet.top, sheet.right, sheet.bottom)
        : Rect.fromLTRB(sheet.left, sheet.center.dy, sheet.right, sheet.bottom);

    _sheet(canvas, stays, depth + 1, layers, made, making, whole);

    // The flap, about the crease: a cosine of width, which is a mirror
    // by the time it is all the way over.
    final k = math.cos(over * math.pi);
    canvas.save();
    if (down) {
      canvas.translate(goes.left, 0);
      canvas.scale(k, 1);
      canvas.translate(-goes.left, 0);
    } else {
      canvas.translate(0, goes.top);
      canvas.scale(1, k);
      canvas.translate(0, -goes.top);
    }
    _sheet(canvas, goes, depth + 1, layers + 1, made, making, whole);
    canvas.restore();
  }

  /// The heart, clipped to the paper that is left of it.
  void _heart(Canvas canvas, Rect sheet, int layers, Size whole) {
    canvas.save();
    canvas.clipRect(sheet);
    canvas.drawPath(heartPath(whole), Paint()..color = layers == 0 ? color : _darker(color, layers));
    canvas.restore();
  }

  /// Each layer of paper over the last takes a little light with it.
  static Color _darker(Color base, int layers) => Color.lerp(base, const Color(0xFF000000), (0.13 * layers).clamp(0.0, 0.55))!;

  /// A heart drawn to fill [size]: two lobes and a point, the shape the
  /// app wears everywhere else.
  static Path heartPath(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w * 0.5, h * 0.92)
      ..cubicTo(w * 0.06, h * 0.62, w * 0.02, h * 0.34, w * 0.20, h * 0.16)
      ..cubicTo(w * 0.35, h * 0.02, w * 0.46, h * 0.12, w * 0.5, h * 0.26)
      ..cubicTo(w * 0.54, h * 0.12, w * 0.65, h * 0.02, w * 0.80, h * 0.16)
      ..cubicTo(w * 0.98, h * 0.34, w * 0.94, h * 0.62, w * 0.5, h * 0.92)
      ..close();
  }

  @override
  bool shouldRepaint(_FoldedHeart old) => old.at != at || old.color != color;
}
