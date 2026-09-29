/// The heart folds; it does not shrink.
///
/// Every step is read off the pixels rather than off the code: the
/// painter is rasterised at a point of the turn and what it covered is
/// measured. A fold halves one dimension and leaves the other, and
/// what it leaves has to fit in the paper the folds so far allow —
/// paper folded in half twice on one axis is a quarter of it, not two
/// halves lying side by side.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/folding_heart.dart';

const _side = 120.0;

/// One frame at sixty a second, which is what a turn needs to be told
/// it is over.
const frame = Duration(milliseconds: 16);
const _size = Size(_side, _side);

/// What the heart covers at this point of the turn, in pixels.
Future<Rect> painted(double at) async {
  final recorder = ui.PictureRecorder();
  FoldingHeart.painterAt(at, Palette.gold).paint(Canvas(recorder), _size);
  final image = await recorder.endRecording().toImage(_side.toInt(), _side.toInt());
  final data = (await image.toByteData())!;
  var left = _side, top = _side, right = 0.0, bottom = 0.0;
  for (var y = 0; y < _side; y++) {
    for (var x = 0; x < _side; x++) {
      if (data.getUint8((y * _side.toInt() + x) * 4 + 3) == 0) continue;
      if (x < left) left = x.toDouble();
      if (x + 1 > right) right = x + 1.0;
      if (y < top) top = y.toDouble();
      if (y + 1 > bottom) bottom = y + 1.0;
    }
  }
  image.dispose();
  return right <= left ? Rect.zero : Rect.fromLTRB(left, top, right, bottom);
}

/// Where the heart on screen has got to in its turn.
double turnAt(WidgetTester tester) => FoldingHeart.atOf(
  tester.widget<CustomPaint>(find.descendant(of: find.byType(FoldingHeart), matching: find.byType(CustomPaint))).painter!,
);

void main() {
  testWidgets('one turn, then a rest, and nothing asked for while it rests', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: FoldingHeart(size: 46, color: Palette.gold)),
        ),
      ),
    );
    expect(turnAt(tester), 0, reason: 'whole, to begin with');
    // And still, for a beat: seen as a heart before it folds.
    await tester.pump(FoldingHeart.first - const Duration(milliseconds: 100));
    expect(turnAt(tester), 0, reason: 'still whole a moment before its first turn');
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'and asking for nothing while it waits');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(frame);

    await tester.pump(FoldingHeart.turn ~/ 2);
    expect(turnAt(tester), closeTo(0.5, 0.02), reason: 'shut, half way through the turn');
    expect(tester.binding.transientCallbackCount, 1, reason: 'ticking, because it is folding');
    await tester.pump(FoldingHeart.turn ~/ 2);
    expect(turnAt(tester), 1, reason: 'and whole again, the turn over');

    // Resting. This is the part that is new: the heart is not folding,
    // and nothing is being drawn for it either. One more frame is what
    // tells the turn it is over — a run is done on the tick past its
    // end, not on the tick that reaches it.
    await tester.pump(frame);
    expect(tester.binding.transientCallbackCount, 0, reason: 'nothing is ticking');
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'and a heart at rest asks for no frames');

    await tester.pump(FoldingHeart.every - FoldingHeart.turn - const Duration(seconds: 1));
    expect(turnAt(tester), 1, reason: 'still whole, still still');
    expect(tester.binding.hasScheduledFrame, isFalse);

    // A period after it began, it goes again.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(FoldingHeart.turn ~/ 2);
    expect(turnAt(tester), closeTo(0.5, 0.03), reason: 'round again, one period on');
  });

  testWidgets('a reader who asked for less movement gets a heart that never moves', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(child: FoldingHeart(size: 46, color: Palette.gold)),
          ),
        ),
      ),
    );
    await tester.pump(FoldingHeart.turn);
    expect(turnAt(tester), 0);
    expect(tester.binding.transientCallbackCount, 0, reason: 'and no frames are asked for on their behalf');
  });

  test('each fold halves the paper, and the last one shuts it', () async {
    final whole = await painted(0);
    expect(whole.width, greaterThan(_side * 0.75));
    expect(whole.height, greaterThan(_side * 0.75));

    var last = whole;
    for (var fold = 1; fold <= FoldingHeart.folds; fold++) {
      final now = await painted(FoldingHeart.afterFold(fold));
      final packet = FoldingHeart.packetAfter(fold, _size);
      // Inside the paper the folds have left, and filling it: the
      // flap has come over onto what it was folded from, not beside it.
      expect(
        packet.inflate(1).contains(now.topLeft) && packet.inflate(1).contains(now.bottomRight),
        isTrue,
        reason: 'after fold $fold the paper is $packet, and $now is drawn',
      );
      expect(now.width, greaterThan(packet.width * 0.7), reason: 'and it still fills it');
      // The axis this fold did not touch is untouched.
      final sideways = fold.isOdd; // vertical, horizontal, vertical
      expect(sideways ? now.height : now.width, closeTo(sideways ? last.height : last.width, 2), reason: 'fold $fold is on one axis');
      last = now;
    }

    // Shutting is a fold too. The last one was vertical, so it is the
    // width that goes; a shrink about the middle would take both.
    final closing = await painted(FoldingHeart.whileShutting(0.5));
    expect(closing.width, lessThan(last.width * 0.85), reason: 'shutting takes the width');
    expect(closing.height, closeTo(last.height, 2), reason: 'and leaves the height, the way a book closes');

    final shut = await painted(FoldingHeart.whileShutting(1));
    expect(shut.width, lessThanOrEqualTo(2), reason: 'edge-on, and there is nothing to see');
  });
}
