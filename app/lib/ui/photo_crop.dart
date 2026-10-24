/// Choosing which part of a photograph is the picture.
///
/// Taking the middle square is what a computer would do and it is
/// wrong about half the time: people are not in the middle of their own
/// photographs, and a badge is small, so a head cut off at the chin is
/// the whole of what anyone sees. So the square stays put
/// and the photograph moves under it — drag to move it, pinch to make
/// it bigger — and what is kept is what is in the square.
///
/// The geometry is [Window], on its own and without a widget, because
/// it is the part that can be wrong in ways nobody notices until they
/// are looking at their own chin.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// What a square window of [side] is looking at, over a picture of
/// [picture] pixels.
///
/// [scale] is 1 when the picture is just big enough to cover the
/// window — the least it is ever shown at, since a smaller one would
/// leave the window half empty — and [offset] is how far it has been
/// dragged from centred, in the window's own pixels.
@immutable
class Window {
  const Window({required this.picture, required this.side, this.scale = 1, this.offset = Offset.zero});

  final Size picture;
  final double side;
  final double scale;
  final Offset offset;

  /// How far out the picture is at all, and the most anyone can push
  /// it: past this and a badge is made of four pixels.
  static const most = 6.0;

  /// The scale at which the picture just covers the window.
  double get cover => side / min(picture.width, picture.height);

  /// The size the picture is drawn at.
  Size get drawn => Size(picture.width * cover * scale, picture.height * cover * scale);

  /// How far the picture may be dragged before the window would see
  /// past its edge.
  Offset get room => Offset((drawn.width - side) / 2, (drawn.height - side) / 2);

  /// The same window with [offset] pulled back inside the picture, and
  /// [scale] held between covering the window and [most].
  Window get held {
    final kept = scale.clamp(1.0, most);
    final at = Window(picture: picture, side: side, scale: kept, offset: offset);
    return Window(
      picture: picture,
      side: side,
      scale: kept,
      offset: Offset(
        offset.dx.clamp(-at.room.dx, at.room.dx),
        offset.dy.clamp(-at.room.dy, at.room.dy),
      ),
    );
  }

  /// What the window is looking at, in the picture's own pixels. The
  /// rectangle a crop takes.
  Rect get looking {
    final shown = cover * scale;
    final at = held;
    return Rect.fromLTWH(
      (at.drawn.width - side) / 2 / shown - at.offset.dx / shown,
      (at.drawn.height - side) / 2 / shown - at.offset.dy / shown,
      side / shown,
      side / shown,
    );
  }

  Window movedBy(Offset by) => Window(picture: picture, side: side, scale: scale, offset: offset + by).held;

  /// Pinched to [by] times the scale, about [about] in the window's own
  /// coordinates, so what is under the fingers stays under them.
  Window scaledBy(double by, {Offset? about}) {
    final kept = (scale * by).clamp(1.0, most);
    final grew = kept / scale;
    final centre = about ?? Offset(side / 2, side / 2);
    final fromMiddle = centre - Offset(side / 2, side / 2);
    return Window(
      picture: picture,
      side: side,
      scale: kept,
      offset: (offset - fromMiddle) * grew + fromMiddle,
    ).held;
  }
}

/// The picture with the square over it, and the two things to do.
class PhotoCrop extends StatefulWidget {
  const PhotoCrop({super.key, required this.bytes, required this.picture, this.side = 260});

  /// The photograph, as picked.
  final Uint8List bytes;

  /// Its size in pixels, which is what the geometry is about.
  final Size picture;

  /// The window on screen.
  final double side;

  @override
  State<PhotoCrop> createState() => _PhotoCropState();
}

class _PhotoCropState extends State<PhotoCrop> {
  late Window _window = Window(picture: widget.picture, side: widget.side);

  /// How far apart the fingers were at the last update, against when
  /// they went down: the scale an update gives is the whole pinch so
  /// far, and the window grows by what it adds since the last.
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    final at = _window;
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(context.l10n.yourPicture, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_window.looking),
            style: TextButton.styleFrom(foregroundColor: Palette.gold),
            child: Text(context.l10n.useIt, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onScaleStart: (_) => _scale = 1,
              // Each update is the step since the last: grown about where
              // the fingers were, then moved as far as they went, so what
              // is under them stays under them.
              onScaleUpdate: (d) => setState(() {
                final by = _scale > 0 ? d.scale / _scale : 1.0;
                _window = _window.scaledBy(by, about: d.localFocalPoint - d.focalPointDelta).movedBy(d.focalPointDelta);
                _scale = d.scale;
              }),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.side / 2),
                child: SizedBox(
                  width: widget.side,
                  height: widget.side,
                  child: Stack(
                    children: [
                      Positioned(
                        left: -at.room.dx + at.offset.dx,
                        top: -at.room.dy + at.offset.dy,
                        width: at.drawn.width,
                        height: at.drawn.height,
                        child: Image.memory(widget.bytes, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              context.l10n.cropHelp,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, height: 1.5, color: Palette.chromeDim),
            ),
          ],
        ),
      ),
    );
  }
}
