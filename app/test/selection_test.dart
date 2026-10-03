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
}
