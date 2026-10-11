/// A QR code, painted.
///
/// The one place this app shows a machine-readable thing to another
/// machine: a link a second device arrives by (docs/06-service.md). The
/// scanner is whatever camera the other phone already has, so what is
/// drawn has to be read across a table in a room with the curtains
/// open — which is the whole of the design here. Dark on white with a
/// quiet zone around it, and never the felt: a code on a dark ground
/// is a code half the scanners in the world will not look at twice.
library;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../l10n/l10n.dart';

class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    // The lowest correction level that still carries it: a code with
    // less redundancy is a code with larger modules at the same size,
    // and larger modules read from further away. Nothing here is going
    // to be printed on a box and scuffed.
    final code = QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.low);
    final image = QrImage(code);
    return Semantics(
      label: context.l10n.codeToScan,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
        child: CustomPaint(painter: _QrPainter(image), size: Size.square(size - 24)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    // Whole pixels a module, so no row is drawn a half-pixel wider than
    // its neighbour: a camera reading an uneven grid gives up.
    final module = (size.width / count).floorToDouble();
    if (module < 1) return;
    final drawn = module * count;
    final left = (size.width - drawn) / 2;
    final top = (size.height - drawn) / 2;
    final ink = Paint()..color = Colors.black;
    for (var y = 0; y < count; y++) {
      for (var x = 0; x < count; x++) {
        if (!image.isDark(y, x)) continue;
        canvas.drawRect(Rect.fromLTWH(left + x * module, top + y * module, module, module), ink);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
