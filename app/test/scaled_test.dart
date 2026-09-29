/// A piece of the table drawn bigger: laid out in less room, drawn in
/// more, and touched where it is drawn (ui/scaled.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/scaled.dart';

void main() {
  testWidgets('it takes up the room it is drawn in, and its child the room it is laid out in', (tester) async {
    await tester.pumpWidget(const Center(
      child: Scaled(scale: 1.5, child: SizedBox(width: 40, height: 20)),
    ));
    expect(tester.getSize(find.byType(Scaled)), const Size(60, 30));
    expect(tester.renderObject<RenderBox>(find.byType(SizedBox)).size, const Size(40, 20));
    expect(tester.getRect(find.byType(SizedBox)), tester.getRect(find.byType(Scaled)));
  });

  testWidgets('the room it is given is shared out at its scale', (tester) async {
    await tester.pumpWidget(const Center(
      child: SizedBox(
        width: 300,
        child: Scaled(scale: 2, child: SizedBox(width: double.infinity, height: 10)),
      ),
    ));
    expect(tester.renderObject<RenderBox>(find.byType(SizedBox).last).size.width, 150);
    expect(tester.getSize(find.byType(Scaled)), const Size(300, 20));
  });

  testWidgets('its dry layout and intrinsics are its layout, at its scale', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Scaled(scale: 2, child: Text('Hearts', style: TextStyle(fontSize: 10)))),
    ));
    final scaled = tester.renderObject<RenderScaled>(find.byType(Scaled));
    final text = tester.renderObject<RenderBox>(find.text('Hearts'));
    expect(scaled.getDryLayout(const BoxConstraints()), scaled.size);
    expect(scaled.getMaxIntrinsicWidth(double.infinity), text.getMaxIntrinsicWidth(double.infinity) * 2);
    expect(scaled.getMinIntrinsicHeight(double.infinity), text.getMinIntrinsicHeight(double.infinity) * 2);
  });

  testWidgets('its baseline is its child\'s, where it is drawn', (tester) async {
    // Twenty points of text beside ten drawn at twice the size: on one
    // baseline, the two are drawn the same.
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('a', style: TextStyle(fontSize: 20)),
            Scaled(scale: 2, child: Text('b', style: TextStyle(fontSize: 10))),
          ],
        ),
      ),
    ));
    final a = tester.getRect(find.text('a'));
    final b = tester.getRect(find.text('b'));
    expect(b.top, closeTo(a.top, 1e-9));
    expect(b.height, closeTo(a.height, 1e-9));
  });

  testWidgets('a touch lands on what is drawn under it', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: Scaled(
          scale: 2,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 50, height: 20),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tapped++,
              child: const SizedBox(width: 50, height: 20),
            ),
          ]),
        ),
      ),
    ));
    // Laid out at 50 to 100, drawn at 100 to 200.
    await tester.tapAt(const Offset(75, 20));
    expect(tapped, 0);
    await tester.tapAt(const Offset(150, 20));
    expect(tapped, 1);
  });

  testWidgets('at a scale of one it is its child, and a new scale lays it out again', (tester) async {
    Widget at(double scale) => Center(child: Scaled(scale: scale, child: const SizedBox(width: 40, height: 20)));
    await tester.pumpWidget(at(1));
    expect(tester.getRect(find.byType(SizedBox)), tester.getRect(find.byType(Scaled)));
    expect(tester.getSize(find.byType(Scaled)), const Size(40, 20));
    await tester.pumpWidget(at(2));
    expect(tester.getSize(find.byType(Scaled)), const Size(80, 40));
    await tester.pumpWidget(at(1));
    expect(tester.getSize(find.byType(Scaled)), const Size(40, 20));
  });

  testWidgets('drawn over something that composites, it carries its scale in a layer of its own', (tester) async {
    Widget at(double scale) => Center(
          child: Scaled(
            scale: scale,
            child: const RepaintBoundary(child: SizedBox(width: 40, height: 20)),
          ),
        );
    await tester.pumpWidget(at(2));
    final layer = tester.renderObject<RenderScaled>(find.byType(Scaled)).debugLayer;
    expect(layer, isA<TransformLayer>());
    expect((layer! as TransformLayer).transform!.getMaxScaleOnAxis(), 2);
    // And back to one: no layer, since there is nothing to carry.
    await tester.pumpWidget(at(1));
    expect(tester.renderObject<RenderScaled>(find.byType(Scaled)).debugLayer, isNull);
  });
}
