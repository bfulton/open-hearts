/// Which part of a photograph becomes the picture.
///
/// The geometry first, on its own: it is the part that can be wrong in
/// ways nobody notices until they are looking at their own chin. Then
/// the whole of it — a picture with four different corners, dragged and
/// pinched, and the pixels that come out the other end.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/photo_crop.dart';

/// A picture that is one colour on the left and another on the right.
Uint8List _halves({int width = 400, int height = 200}) {
  final picture = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      picture.setPixelRgb(x, y, x < width ~/ 2 ? 220 : 20, 20, x < width ~/ 2 ? 20 : 220);
    }
  }
  return Uint8List.fromList(img.encodePng(picture));
}

/// The colour in the middle of a finished badge.
({int r, int g, int b}) _middleOf(Uint8List jpeg) {
  final small = img.decodeImage(jpeg)!;
  final p = small.getPixel(small.width ~/ 2, small.height ~/ 2);
  return (r: p.r.round(), g: p.g.round(), b: p.b.round());
}

void main() {
  group('the window, on its own', () {
    test('a picture that is already square is looked at whole', () {
      const w = Window(picture: Size(400, 400), side: 200);
      expect(w.looking, const Rect.fromLTWH(0, 0, 400, 400));
      expect(w.scale, 1);
    });

    test('a wide picture is looked at through its middle, and a tall one likewise', () {
      const wide = Window(picture: Size(400, 200), side: 100);
      expect(wide.looking, const Rect.fromLTWH(100, 0, 200, 200), reason: 'the middle square of a wide picture');
      const tall = Window(picture: Size(200, 400), side: 100);
      expect(tall.looking, const Rect.fromLTWH(0, 100, 200, 200));
    });

    test('dragging moves the window the other way, since it is the picture that moves', () {
      const wide = Window(picture: Size(400, 200), side: 100);
      // The picture is drawn at 200x100 on screen, so a screen pixel is
      // two picture pixels: dragging it fifty to the right shows a
      // hundred less of the picture's left.
      final right = wide.movedBy(const Offset(50, 0));
      expect(right.looking, const Rect.fromLTWH(0, 0, 200, 200));
      final left = wide.movedBy(const Offset(-50, 0));
      expect(left.looking, const Rect.fromLTWH(200, 0, 200, 200));
    });

    test('the window is never let off the edge of the picture', () {
      const wide = Window(picture: Size(400, 200), side: 100);
      final far = wide.movedBy(const Offset(9999, 9999));
      expect(far.looking, const Rect.fromLTWH(0, 0, 200, 200), reason: 'held at the left edge');
      expect(far.looking.top, 0, reason: 'and a picture with no room up and down does not move up and down');
      final other = wide.movedBy(const Offset(-9999, 0));
      expect(other.looking.right, 400);
    });

    test('pinching looks at less of the picture, and is held between covering it and six times', () {
      const square = Window(picture: Size(400, 400), side: 200);
      final closer = square.scaledBy(2);
      expect(closer.looking, const Rect.fromLTWH(100, 100, 200, 200), reason: 'half as much, from the middle');
      expect(square.scaledBy(0.1).scale, 1, reason: 'never less than covers the window');
      expect(square.scaledBy(99).scale, Window.most);
    });

    test('pinching about a corner keeps what is under the fingers under them', () {
      const square = Window(picture: Size(400, 400), side: 200);
      // Pinching about the top-left of the window: that corner is
      // looking at the picture's own top-left, and still is after.
      final closer = square.scaledBy(2, about: Offset.zero);
      expect(closer.looking.topLeft, Offset.zero);
      expect(closer.looking.width, 200, reason: 'twice as close is half the picture');
      // And about the bottom-right corner, the other way.
      final other = square.scaledBy(2, about: const Offset(200, 200));
      expect(other.looking.bottomRight, const Offset(400, 400));
    });

    test('a window zoomed in is held inside the picture like any other', () {
      const square = Window(picture: Size(400, 400), side: 200);
      final far = square.scaledBy(2).movedBy(const Offset(9999, 0));
      expect(far.looking.left, 0);
      expect(far.looking.width, 200);
    });
  });

  group('the picture that comes out', () {
    test('with nobody saying otherwise it is still the middle square', () {
      final small = shrinkPicture(_halves())!;
      final middle = _middleOf(small);
      // The middle of a wide picture split down the middle: the seam,
      // so neither side wholly wins. What matters is that it is the
      // middle and not an edge, which the crops below move off.
      expect(small.length, lessThanOrEqualTo(Avatar.maxPictureBytes));
      expect(img.decodeImage(small)!.width, Avatar.side);
      expect(middle.g, lessThan(100), reason: 'neither half is green');
    });

    test('a window over one half keeps that half, and over the other keeps the other', () {
      final bytes = _halves();
      final left = _middleOf(shrinkPicture(bytes, from: const Rect.fromLTWH(0, 0, 200, 200))!);
      expect(left.r, greaterThan(150), reason: 'the left half is red');
      expect(left.b, lessThan(100));
      final right = _middleOf(shrinkPicture(bytes, from: const Rect.fromLTWH(200, 0, 200, 200))!);
      expect(right.b, greaterThan(150), reason: 'and the right half is blue');
      expect(right.r, lessThan(100));
    });

    test('a window that ran off the edge is pulled back rather than thrown', () {
      final bytes = _halves();
      final off = shrinkPicture(bytes, from: const Rect.fromLTWH(380, -40, 200, 200));
      expect(off, isNotNull);
      expect(_middleOf(off!).b, greaterThan(150), reason: 'held against the right edge, which is blue');
    });
  });

  group('the page', () {
    /// The crop page over a picture, and what it hands back.
    Future<Rect?> crop(WidgetTester tester, Uint8List bytes, Size picture, Future<void> Function(WidgetTester) doIt) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Rect? kept;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              kept = await Navigator.of(context).push<Rect>(
                MaterialPageRoute<Rect>(builder: (_) => PhotoCrop(bytes: bytes, picture: picture, side: 200)),
              );
            },
            child: const Text('pick'),
          ),
        ),
      ));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      await doIt(tester);
      await tester.tap(find.text('Use it'));
      await tester.pumpAndSettle();
      return kept;
    }

    testWidgets('untouched, it hands back the middle square', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (_) async {});
      expect(kept, const Rect.fromLTWH(100, 0, 200, 200));
    });

    // A drag through the framework loses its first few pixels to the
    // touch slop, so these ask for far more than the picture has room
    // for: where it comes to rest is the edge, exactly, and the number
    // that gets there is the geometry's own business above.
    testWidgets('dragged as far as it goes, it hands back the end of the picture', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (tester) async {
        await tester.drag(find.byType(Image), const Offset(9999, 0));
        await tester.pumpAndSettle();
      });
      expect(kept, const Rect.fromLTWH(0, 0, 200, 200), reason: 'the picture pulled right shows its left');
    });

    // A finger moves a few pixels a frame, and the picture goes the whole
    // way with it, not just the last few pixels.
    testWidgets('dragged a little at a time, the picture follows the finger all the way', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (tester) async {
        final finger = await tester.startGesture(tester.getCenter(find.byType(Image)));
        for (var i = 0; i < 12; i++) {
          await finger.moveBy(const Offset(5, 0));
          await tester.pump();
        }
        await finger.up();
        await tester.pumpAndSettle();
      });
      expect(kept, const Rect.fromLTWH(40, 0, 200, 200), reason: '60 pixels right, of the 100 the picture has room for');
    });

    // The picture stops at its edge however far the finger goes, and
    // starts back the moment the finger does.
    testWidgets('dragged past the edge and back, it comes back as soon as the finger does', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (tester) async {
        final finger = await tester.startGesture(tester.getCenter(find.byType(Image)));
        for (var i = 0; i < 30; i++) {
          await finger.moveBy(const Offset(5, 0));
          await tester.pump();
        }
        for (var i = 0; i < 6; i++) {
          await finger.moveBy(const Offset(-5, 0));
          await tester.pump();
        }
        await finger.up();
        await tester.pumpAndSettle();
      });
      expect(kept, const Rect.fromLTWH(30, 0, 200, 200), reason: 'held at 100 pixels right, then 30 back');
    });

    // Two fingers spreading to twice as far apart while both move 30
    // pixels right: what was under them at the start, the picture's
    // middle, is under them at the end. The outer finger moves first,
    // so the pinch never closes below where it began, where the picture
    // is as small as it goes.
    testWidgets('pinched while moving, what was under the fingers stays under them', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (tester) async {
        final middle = tester.getCenter(find.byType(Image));
        final one = await tester.startGesture(middle - const Offset(20, 0), pointer: 1);
        final two = await tester.startGesture(middle + const Offset(20, 0), pointer: 2);
        for (var i = 0; i < 10; i++) {
          await two.moveBy(const Offset(5, 0));
          await one.moveBy(const Offset(1, 0));
          await tester.pump();
        }
        await one.up();
        await two.up();
        await tester.pumpAndSettle();
      });
      expect(kept, rectMoreOrLessEquals(const Rect.fromLTWH(135, 50, 100, 100)), reason: 'twice as big, the middle 30 pixels right');
    });

    /// Two fingers either side of the middle, [from] apart, spread to
    /// [to] apart a step at a time and lifted.
    Future<void> pinch(WidgetTester tester, double from, double to) async {
      final middle = tester.getCenter(find.byType(ClipRRect).last);
      final one = await tester.startGesture(middle - Offset(from / 2, 0), pointer: 1);
      final two = await tester.startGesture(middle + Offset(from / 2, 0), pointer: 2);
      for (var i = 0; i < 10; i++) {
        await two.moveBy(Offset((to - from) / 20, 0));
        await one.moveBy(Offset(-(to - from) / 20, 0));
        await tester.pump();
      }
      await one.up();
      await two.up();
      await tester.pumpAndSettle();
    }

    testWidgets('pinched twice, the second takes up where the first left off', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (tester) async {
        await pinch(tester, 40, 80);
        await pinch(tester, 40, 60);
      });
      expect(
        kept,
        rectMoreOrLessEquals(Rect.fromCenter(center: const Offset(200, 100), width: 200 / 3, height: 200 / 3)),
        reason: 'twice, then half as big again',
      );
    });

    testWidgets('fingers pinched together to one point leave it as small as it goes, not broken', (tester) async {
      final kept = await crop(tester, _halves(), const Size(400, 200), (tester) async {
        final middle = tester.getCenter(find.byType(ClipRRect).last);
        final one = await tester.startGesture(middle - const Offset(20, 0), pointer: 1);
        final two = await tester.startGesture(middle + const Offset(20, 0), pointer: 2);
        await one.moveBy(const Offset(20, 0));
        await two.moveBy(const Offset(-20, 0));
        await tester.pump();
        await one.moveBy(Offset.zero);
        await two.moveBy(Offset.zero);
        await tester.pump();
        await one.up();
        await two.up();
        await tester.pumpAndSettle();
      });
      expect(kept, const Rect.fromLTWH(100, 0, 200, 200));
    });

    testWidgets('and what it hands back is what ends up on the badge', (tester) async {
      final bytes = _halves();
      final kept = await crop(tester, bytes, const Size(400, 200), (tester) async {
        await tester.drag(find.byType(Image), const Offset(-9999, 0));
        await tester.pumpAndSettle();
      });
      expect(kept, const Rect.fromLTWH(200, 0, 200, 200));
      expect(_middleOf(shrinkPicture(bytes, from: kept!)!).b, greaterThan(150), reason: 'the blue half');
    });
  });
}
