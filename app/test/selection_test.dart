/// Selecting text and copying it, on a phone's screen: the long press
/// selects a word, and the toolbar it raises has Copy in it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/selection.dart';

void main() {
  testWidgets('a long press selects a word and offers Copy', (tester) async {
    await tester.pumpWidget(MaterialApp(
      // As main.dart has it: around the whole app, above the navigator,
      // whose overlay is therefore no use to it.
      builder: (context, child) => CopyableSelection(child: child ?? const SizedBox()),
      home: const Scaffold(body: Center(child: Text('Hearts is a card game'))),
    ));
    await tester.longPressAt(tester.getCenter(find.text('Hearts is a card game')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Copy'), findsOneWidget, reason: 'the toolbar, with Copy in it');

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, isNotNull, reason: 'something copied');
    expect('Hearts is a card game'.contains(copied!.trim()), isTrue, reason: 'a word of the text: "$copied"');
    expect(copied!.trim(), isNotEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

  // Words selected, then gone from the screen (a menu that closed, a line
  // of the table rewritten), and then a drag across the screen: Flutter
  // raises the toolbar for the selection that is no longer there, and a
  // toolbar that asks where to go throws. In a release the error's
  // stand-in, grey, covers the whole screen.
  for (final select in const ['long press', 'double tap']) {
    testWidgets('a $select on words that then go, and a drag: no toolbar, and nothing thrown', (tester) async {
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => CopyableSelection(child: child ?? const SizedBox()),
        home: Scaffold(
          body: Column(children: [
            const SizedBox(height: 100),
            ValueListenableBuilder(
              valueListenable: shown,
              builder: (context, shown, _) => shown ? const Text('Your turn') : const SizedBox(height: 20),
            ),
            const SizedBox(height: 300),
          ]),
        ),
      ));
      final at = tester.getCenter(find.text('Your turn'));
      if (select == 'long press') {
        await tester.longPressAt(at);
      } else {
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at);
      }
      await tester.pumpAndSettle();
      shown.value = false;
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(300, 350), const Offset(-80, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('Copy'), findsNothing, reason: 'nothing selected, nothing to copy');
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));
  }
}
