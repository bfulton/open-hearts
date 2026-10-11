/// The menu drops down from its button, which stays in sight, and a
/// tap on the button again shuts it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/header.dart';

void main() {
  testWidgets('the menu opens below its button, and the button shuts it again', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var chosen = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: MenuButton(menu: [
            MenuAction('First', icon: Icons.star_outline, onSelected: () => chosen++),
            MenuAction('Second', icon: Icons.info_outline, onSelected: () {}),
          ]),
        ),
      ),
    ));
    final button = tester.getRect(find.byType(MenuButton));

    await tester.tap(find.byType(MenuButton));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    final menu = tester.getRect(find.ancestor(of: find.text('First'), matching: find.byType(Material)).first);
    expect(menu.top, greaterThanOrEqualTo(button.bottom - 0.5), reason: 'the menu is below the button, not over it');

    // The button again: the menu shuts, and nothing is chosen.
    await tester.tapAt(button.center);
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(chosen, 0);

    // And opens again, and an entry still acts.
    await tester.tap(find.byType(MenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(chosen, 1);
  });
}
