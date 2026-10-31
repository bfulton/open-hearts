// Runs before every test file here (package:flutter_test's convention).
import 'dart:async';

import 'package:open_hearts/net/licence.dart' show houseKey;
import 'package:open_hearts/ui/table_view.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The "your turn" pill breathes for as long as the turn is yours, so a
  // test that waits for the table to settle would wait for ever. It is
  // still and glowing here; table_page_test.dart watches it breathe.
  turnPillBreathes = false;
  // The house the tables here are seated with, as the browser rig's
  // build names it (e2e/build.sh): BIP-340's third published pair.
  houseKey = 'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8';
  await testMain();
}
