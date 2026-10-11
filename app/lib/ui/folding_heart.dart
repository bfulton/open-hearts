/// The heart at the front door, folded away and opened out again every
/// so often.
///
/// A flourish, not a fidget: it folds, comes back, and then is simply a
/// heart until its next turn comes round. Between turns nothing is
/// drawn and no frame is asked for, which matters on a door that may
/// be left open in a tab all evening.
///
/// A sheet of paper folded in half three times and then shut away,
/// which is the trick: each fold leaves half of what it had, the
/// folded flap lying over what it came from a shade darker, so the
/// whole thing reads as paper rather than as a picture being squashed.
/// Then it comes back out the way it went in.
///
/// The last step is a fold too, not a vanishing: the packet the three
/// folds leave turns about its own last crease until it is edge-on and
/// there is nothing to see — the way a book closes. Shrinking it about
/// its middle instead would read as the picture being taken away rather
/// than the paper being folded.
///
/// The fold itself is a flat cheat — the flap keeps its far edge
/// on the crease and loses its width as the cosine of how far over it
/// has come — which is what a fold looks like from straight on, and
/// straight on is where the door is looked at from.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Where a fold's crease lies and which way the flap goes over.
enum _Crease { vertical, horizontal }

class FoldingHeart extends StatefulWidget {
  const FoldingHeart({super.key, required this.size, required this.color, this.period = every, this.at});

  final double size;
  final Color color;

  /// How often the heart folds away and opens out again, counted from
  /// the start of one turn to the start of the next.
  final Duration period;

  /// The cadence, and how long one turn of it takes. What is left of
  /// the period after a turn is spent whole and still.
  static const every = Duration(seconds: 20);
  static const turn = Duration(seconds: 9);

  /// How long a door just opened shows the heart whole before its first
  /// turn: a heart has to be seen as one before its folding reads as a
  /// flourish.
  static const first = Duration(seconds: 3);

  /// Held at this point of the turn rather than turning, for a still
  /// picture of it — a screenshot, or a test reading one frame.
  final double? at;

  /// How many folds are made before the packet is shut away.
  static int get folds => _FoldedHeart._folds.length;

  /// The paper the first [n] folds leave: each one keeps the half its
  /// crease is on, so the packet is the corner they lead to.
  static Rect packetAfter(int n, Size size) => _FoldedHeart.packetIn(size, folds: n);

  /// The point of the turn at which fold [n] is just made, and the one
  /// at which the packet is [howFar] shut. Named rather than counted,
  /// so what looks at one step of the turn does not carry a copy of
  /// the timings around with it.
  static double afterFold(int n) => _FoldedHeart._at(_FoldedHeart._still + n * _FoldedHeart._foldFor);
  static double whileShutting(double howFar) =>
      _FoldedHeart._at(_FoldedHeart._still + folds * _FoldedHeart._foldFor + howFar * _FoldedHeart._shutFor);

  /// The painter for one point of the turn, for a test that would
  /// rather read the pixels than the arithmetic, and where a painter
  /// on the screen has got to.
  @visibleForTesting
  static CustomPainter painterAt(double at, Color color) => _FoldedHeart(at: at, color: color);

  @visibleForTesting
  static double atOf(CustomPainter painter) => (painter as _FoldedHeart).at;

  @override
  State<FoldingHeart> createState() => _FoldingHeartState();
}

class _FoldingHeartState extends State<FoldingHeart> with SingleTickerProviderStateMixin {
  late final AnimationController _folding = AnimationController(vsync: this, duration: _turn)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _rest();
    });

  /// The wait between one turn and the next. A timer rather than a
  /// controller held at its end: a controller that is still running is
  /// a frame every sixteen milliseconds to draw the same heart.
  Timer? _resting;

  /// One fold and unfold. Never longer than the period it has to
  /// happen in, so a short period is a heart that folds without rest
  /// rather than one that never finishes.
  Duration get _turn => widget.period < FoldingHeart.turn ? widget.period : FoldingHeart.turn;

  /// Whether something is holding the heart at a point of the turn: a
  /// caller asking for one frame of it, or a reader who has asked for
  /// less movement — there is nothing in the folding they are missing.
  bool get _held => widget.at != null || MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_held) {
      _resting?.cancel();
      _resting = null;
      _folding.stop();
    } else if (!_folding.isAnimating && _resting == null) {
      _resting = Timer(widget.period < FoldingHeart.first ? widget.period : FoldingHeart.first, () {
        _resting = null;
        if (mounted && !_held) _folding.forward(from: 0);
      });
    }
  }

  void _rest() {
    final rest = widget.period - _turn;
    if (rest <= Duration.zero) {
      _folding.forward(from: 0);
      return;
    }
    _resting = Timer(rest, () {
      _resting = null;
      if (mounted && !_held) _folding.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _resting?.cancel();
    _folding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final held = widget.at ?? (MediaQuery.disableAnimationsOf(context) ? 0.0 : null);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: held != null
            ? CustomPaint(
                painter: _FoldedHeart(at: held, color: widget.color),
              )
            : AnimatedBuilder(
                animation: _folding,
                builder: (_, _) => CustomPaint(
                  painter: _FoldedHeart(at: _folding.value, color: widget.color),
                ),
              ),
      ),
    );
  }
}

/// The heart, in the state the turn is at.
///
/// The turn is: a beat whole, three folds, the packet shut about its
/// last crease, and the same read backwards. A fold keeps the flap's
/// far edge on the crease and takes its width down as the cosine of
/// how far over it has come, which is what a fold looks like from
/// straight on — and straight on is where a front door is looked at
/// from. Shutting is the same cosine over a quarter turn, applied to
/// everything at once.
class _FoldedHeart extends CustomPainter {
  _FoldedHeart({required this.at, required this.color});

  /// Where the turn is, from 0 to 1.
  final double at;
  final Color color;

  /// The three folds, in the order they are made.
  static const _folds = [_Crease.vertical, _Crease.horizontal, _Crease.vertical];

  /// What the turn is spent on, in order: still, three folds, shut.
  /// Shutting takes a fold's time, because that is what it is.
  static const _still = 0.14;
  static const _foldFor = 0.09;
  static const _shutFor = 0.09;

  /// How far through the half-turn everything is done.
  static const _half = _still + 3 * _foldFor + _shutFor;

  /// The point of the whole turn at which the half-turn is at [t].
  static double _at(double t) => t / _half * 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    // The same shape going in and coming out: the second half of the
    // turn is the first half backwards.
    const half = _half;
    final t = (at < 0.5 ? at : 1 - at) / 0.5 * half;
    var made = 0;
    var making = 0.0;
    var shut = 0.0;
    if (t > _still) {
      final into = t - _still;
      made = (into / _foldFor).floor().clamp(0, _folds.length);
      making = made < _folds.length ? (into - made * _foldFor) / _foldFor : 1;
      if (made >= _folds.length) shut = ((into - _folds.length * _foldFor) / _shutFor).clamp(0.0, 1.0);
    }
    canvas.save();
    if (shut > 0) {
      // Shut: the packet the folds have left turns about the last
      // crease it was folded on until it is edge-on. One axis, pinned
      // where the paper is thickest — a book closing, not a picture
      // being scaled away.
      final packet = packetIn(size);
      final k = math.cos(shut * math.pi / 2);
      if (_folds.last == _Crease.vertical) {
        canvas.translate(packet.right, 0);
        canvas.scale(k, 1);
        canvas.translate(-packet.right, 0);
      } else {
        canvas.translate(0, packet.bottom);
        canvas.scale(1, k);
        canvas.translate(0, -packet.bottom);
      }
    }
    _sheet(canvas, Offset.zero & size, 0, 0, made, Curves.easeInOut.transform(making.clamp(0.0, 1.0)), size, false, false);
    canvas.restore();
  }

  /// Where the paper has got to once every fold is made: each fold
  /// keeps the half its crease is on, so the packet is the corner they
  /// all lead to, and its last crease is the edge it shuts about.
  static Rect packetIn(Size size, {int? folds}) {
    var sheet = Offset.zero & size;
    for (final crease in _folds.take(folds ?? _folds.length)) {
      sheet = crease == _Crease.vertical
          ? Rect.fromLTRB(sheet.left, sheet.top, sheet.center.dx, sheet.bottom)
          : Rect.fromLTRB(sheet.left, sheet.top, sheet.right, sheet.center.dy);
    }
    return sheet;
  }

  /// The crease a fold is made on: the middle of whatever is being
  /// folded, which is where the two halves meet whichever of them is
  /// the one that moves.
  static double _crease(Rect sheet, bool down) => down ? sheet.center.dx : sheet.center.dy;

  /// Draws the paper in [sheet]: what the folds from [depth] on have
  /// done to it, at [layers] thicknesses of paper deep.
  ///
  /// [flipX] and [flipY] say whether this piece of paper has been
  /// turned over along each axis by the folds above it. It matters,
  /// because a flap that has been folded once is a mirror of itself,
  /// and the next fold is made on the packet, not on the flap: the
  /// half that stays is the half that stays *in the packet*, which on
  /// a mirrored flap is the other one. Without that, the third fold —
  /// the second on an axis already folded — lays the two halves side
  /// by side instead of one on the other, and the paper opens back out
  /// rather than getting smaller.
  void _sheet(Canvas canvas, Rect sheet, int depth, int layers, int made, double making, Size whole, bool flipX, bool flipY) {
    final over = depth >= _folds.length || depth > made
        ? 0.0
        : depth < made
        ? 1.0
        : making;
    if (over <= 0) return _heart(canvas, sheet, layers, whole);

    final down = _folds[depth] == _Crease.vertical;
    final flipped = down ? flipX : flipY;
    final near = down
        ? Rect.fromLTRB(sheet.left, sheet.top, sheet.center.dx, sheet.bottom)
        : Rect.fromLTRB(sheet.left, sheet.top, sheet.right, sheet.center.dy);
    final far = down
        ? Rect.fromLTRB(sheet.center.dx, sheet.top, sheet.right, sheet.bottom)
        : Rect.fromLTRB(sheet.left, sheet.center.dy, sheet.right, sheet.bottom);
    final stays = flipped ? far : near;
    final goes = flipped ? near : far;

    _sheet(canvas, stays, depth + 1, layers, made, making, whole, flipX, flipY);

    // The flap, about the crease: a cosine of width, which is a mirror
    // by the time it is all the way over — and being a mirror is what
    // the flip below records for the folds after this one.
    final k = math.cos(over * math.pi);
    final crease = _crease(sheet, down);
    canvas.save();
    if (down) {
      canvas.translate(crease, 0);
      canvas.scale(k, 1);
      canvas.translate(-crease, 0);
    } else {
      canvas.translate(0, crease);
      canvas.scale(1, k);
      canvas.translate(0, -crease);
    }
    _sheet(canvas, goes, depth + 1, layers + 1, made, making, whole, down ? !flipX : flipX, down ? flipY : !flipY);
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
