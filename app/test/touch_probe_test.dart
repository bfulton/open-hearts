/// The touch probe: off, nothing over the app; on, where the app saw the
/// last pointer go down, without taking the tap from what is under it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/touch_probe.dart';

void main() {
  testWidgets('the probe says where the app saw a tap, and the tap still lands', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => TouchProbe(child: child!),
      home: Scaffold(body: Center(child: ElevatedButton(onPressed: () => pressed++, child: const Text('Press')))),
    ));
    expect(find.textContaining('app  tap'), findsNothing, reason: 'off: nothing drawn');

    touchProbeOn.value = true;
    addTearDown(() => touchProbeOn.value = false);
    await tester.pump();
    expect(find.textContaining('app  tap -'), findsOneWidget);

    final at = tester.getCenter(find.text('Press'));
    await tester.tapAt(at);
    await tester.pump();
    expect(pressed, 1, reason: 'the tap is the button\'s still');
    expect(find.textContaining('app  tap ${at.dx.round()},${at.dy.round()}'), findsOneWidget);
    touchProbeOn.value = false;
    await tester.pump();
  });
}
