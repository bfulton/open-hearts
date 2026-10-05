/// The app-wide selection and a page covered before it was ever laid
/// out (ui/selection.dart, SelectionWhileCurrent): a page opened by its
/// address over the front door, or a table rejoined as the app starts.
/// The selection orders its text by where each piece is on the screen,
/// and asking the covered page's unmeasured text throws — from a
/// microtask, which fails a test outright. Under a theme without
/// SelectionWhileCurrent, this test fails on that error.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionRegistrar;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/selection.dart';

void main() {
  testWidgets('a page covered from the first frame is out of the selection until it is on top, and nothing throws', (tester) async {
    final tick = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      builder: (context, child) => CopyableSelection(child: child!),
      initialRoute: '/top',
      routes: {
        '/': (_) => Scaffold(
              body: ValueListenableBuilder(
                valueListenable: tick,
                builder: (_, n, _) => Column(children: [Text('online $n'), const Text('more')]),
              ),
            ),
        '/top': (_) => const Scaffold(body: Column(children: [Text('on top'), Text('and more')])),
      },
    ));
    SelectionRegistrar? registrarOf(String text) =>
        SelectionContainer.maybeOf(tester.element(find.text(text, skipOffstage: false)));
    final region = registrarOf('on top');
    expect(region, isNotNull, reason: 'the page on top is in the selection');
    expect(registrarOf('more'), isNot(region), reason: 'the covered one is not');

    // The door's text changing under the page on top, as its online
    // count does.
    for (var i = 0; i < 3; i++) {
      tick.value++;
      await tester.pump(const Duration(seconds: 1));
    }

    // Uncovered: measured, and back in the selection.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(registrarOf('more'), region);
    tick.value++;
    await tester.pump();
    expect(find.text('online 4'), findsOneWidget);
  });
}
