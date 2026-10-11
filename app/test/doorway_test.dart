/// The frame the front door and the two screens that stand in for it
/// share: where the heart sits, whose the title is, and that the fold
/// carries across the change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/doorway.dart';
import 'package:open_hearts/ui/folding_heart.dart';

import 'home_page_test.dart' show still;

void main() {
  testWidgets('the name is the door\'s alone; the heart moves up, and goes on folding', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final heart = GlobalKey();
    Widget frame(bool title) => still(Scaffold(
          body: Doorway(
            heart: FoldingHeart(key: heart, size: 46, color: Palette.mark),
            title: title,
            child: const Text('Finding players'),
          ),
        ));

    await tester.pumpWidget(frame(true));
    await tester.pumpAndSettle();
    expect(find.text('Open Hearts'), findsOneWidget);
    expect(tester.getSize(find.byType(FoldingHeart)), const Size(46, 46), reason: 'a heart, not a column\'s width of one');
    final atTheDoor = tester.getTopLeft(find.byType(FoldingHeart)).dy;
    final folding = heart.currentState;
    expect(folding, isNotNull);

    // Waiting to be seated, or in a room filling up: no name over it,
    // and the heart up out of the way of what the screen has to say.
    await tester.pumpWidget(frame(false));
    await tester.pumpAndSettle();
    expect(find.text('Open Hearts'), findsNothing);
    expect(find.byType(FoldingHeart), findsOneWidget);
    expect(tester.getTopLeft(find.byType(FoldingHeart)).dy, lessThan(atTheDoor), reason: 'higher up than at the door');
    final middle = tester.getSize(find.byType(Doorway)).height / 2;
    final said = tester.getCenter(find.text('Finding players')).dy;
    expect(said, greaterThan(tester.getBottomLeft(find.byType(FoldingHeart)).dy), reason: 'under the heart');
    expect(said, closeTo(middle, 40), reason: 'and in the middle of the screen');

    // The same heart throughout: a fold part way through does not
    // start over because the screen under it changed.
    expect(heart.currentState, same(folding));
  });

  testWidgets('a phone on its side: the name beside the buttons, and nothing to scroll', (tester) async {
    for (final size in const [Size(874, 402), Size(844, 340), Size(667, 300)]) {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1.0;
      await tester.pumpWidget(still(Scaffold(
        body: Doorway(
          heart: FoldingHeart(key: GlobalKey(), size: 46, color: Palette.mark),
          title: true,
          tagline: 'Open source card game, no ads',
          child: const SizedBox(height: 240, child: Placeholder()),
        ),
      )));
      await tester.pumpAndSettle();
      final name = tester.getRect(find.text('Open Hearts'));
      final buttons = tester.getRect(find.byType(Placeholder));
      expect(name.right, lessThan(buttons.left), reason: '$size: the name to the left of the buttons');
      expect(tester.getRect(find.text('Open source card game, no ads')).right, lessThan(buttons.left), reason: '$size: and the tagline with it');
      for (final scroll in tester.stateList<ScrollableState>(find.byType(Scrollable))) {
        expect(scroll.position.maxScrollExtent, 0, reason: '$size: nothing to scroll');
      }
    }
    tester.view.reset();
  });
}
