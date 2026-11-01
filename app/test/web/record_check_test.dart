/// On a page (flutter test --platform chrome): a check its worker could
/// not make ends in an error, which the review page reports, and not in
/// a verdict that says nothing of why.
@TestOn('browser')
library;

import 'package:engine/engine.dart' show Persona;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/record_check.dart';
import 'package:table/table.dart';

void main() {
  test('a worker that cannot run ends the check with an error', () async {
    // No review_worker.js is served beside the tests: the worker fails
    // to load, as it would where its script is missing or broken.
    final game = KeptGame(spec: TableSpec(seed: 1, seats: [for (final p in Persona.roster.take(4)) BotSeat(p)]), text: '{}');
    await expectLater(checkRecord(game), emitsInOrder([emitsError(isStateError), emitsDone]));
  });
}
