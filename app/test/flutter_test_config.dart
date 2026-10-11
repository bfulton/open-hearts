// Runs before every test file here (package:flutter_test's convention).
import 'dart:async';

import 'package:open_hearts/ui/table_view.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The "your turn" pill breathes for as long as the turn is yours, so a
  // test that waits for the table to settle would wait for ever. It is
  // still and glowing here; table_page_test.dart watches it breathe.
  turnPillBreathes = false;
  await testMain();
}
