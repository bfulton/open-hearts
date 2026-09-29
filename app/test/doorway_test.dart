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
}
