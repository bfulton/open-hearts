/// The table's scale: one number for how much bigger than a phone's a
/// table is drawn, and the widget that draws a piece of it that much
/// bigger (docs/05-form-factors.md).
///
/// The cards on a tablet's felt grow to be read from across a desk. The
/// type round them — the names on the badges, the line the table says,
/// the action line and its Pass button, the rail — was a phone's, so a
/// tablet had a big game with small words on it. Now all of it is drawn
/// at the one scale the cards grew by. A phone's table is at exactly
/// one, and is drawn exactly as it was.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The scale of the table below it, for the pieces of it laid out in
/// different places: the felt, the action line, the rail.
class TableScale extends InheritedWidget {
  const TableScale({super.key, required this.scale, required super.child});

  final double scale;

  /// The biggest a card may be on a phone's felt, which is the whole of
  /// what fits one held at arm's length; and the biggest on any felt.
  static const phoneCard = 76.0;
  static const mostCard = 108.0;

  /// The scale of a table whose felt is [felt]: how much bigger than a
  /// phone's its cards may be. A felt's cards may be seventeen
  /// hundredths of its shortest side, between the two above.
  static double forFelt(Size felt) => (felt.shortestSide * 0.17).clamp(phoneCard, mostCard) / phoneCard;

  /// The scale the table below [context] is drawn at, or null outside
  /// one.
  static double? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TableScale>()?.scale;

  @override
  bool updateShouldNotify(TableScale old) => old.scale != scale;
}

/// [child], laid out in [scale] times less room and drawn [scale] times
/// bigger: everything in it — type, icons, padding, the gaps between —
/// grows together, and it takes up the room it is drawn in, so what is
/// round it lays out against the size it looks. Touches land where
/// they look. At a scale of one it is its child, untouched.
class Scaled extends SingleChildRenderObjectWidget {
  const Scaled({super.key, required this.scale, super.child});

  final double scale;

  @override
  RenderScaled createRenderObject(BuildContext context) => RenderScaled(scale);

  @override
  void updateRenderObject(BuildContext context, RenderScaled renderObject) => renderObject.scale = scale;
}

class RenderScaled extends RenderProxyBox {
  RenderScaled(this._scale) : assert(_scale > 0);

  double get scale => _scale;
  double _scale;
  set scale(double value) {
    assert(value > 0);
    if (value == _scale) return;
    _scale = value;
    markNeedsLayout();
  }

  bool get _identity => _scale == 1.0;

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  BoxConstraints _inner(BoxConstraints outer) => _identity
      ? outer
      : BoxConstraints(
          minWidth: outer.minWidth / _scale,
          maxWidth: outer.maxWidth / _scale,
          minHeight: outer.minHeight / _scale,
          maxHeight: outer.maxHeight / _scale,
        );

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_inner(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size * _scale);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(child.getDryLayout(_inner(constraints)) * _scale);
  }

  @override
  double computeMinIntrinsicWidth(double height) => (child?.getMinIntrinsicWidth(height / _scale) ?? 0) * _scale;

  @override
  double computeMaxIntrinsicWidth(double height) => (child?.getMaxIntrinsicWidth(height / _scale) ?? 0) * _scale;

  @override
  double computeMinIntrinsicHeight(double width) => (child?.getMinIntrinsicHeight(width / _scale) ?? 0) * _scale;

  @override
  double computeMaxIntrinsicHeight(double width) => (child?.getMaxIntrinsicHeight(width / _scale) ?? 0) * _scale;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final distance = child?.getDistanceToActualBaseline(baseline);
    return distance == null ? null : distance * _scale;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_identity) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer is TransformLayer ? layer! as TransformLayer : null,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!_identity) transform.multiply(_transform);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    if (_identity) return child.hitTest(result, position: position);
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }
}
