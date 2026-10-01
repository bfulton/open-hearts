/// Where a solo game's cards come from (docs/03-fair-deal.md, "Where
/// the randomness comes from"): a player's game from a deal seed of its
/// own, which its record carries; a test's from its int seed, as ever.
library;

import 'package:engine/engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/record_store.dart';

void main() {
  test('a player\'s game is dealt from a fresh deal seed, and its record carries it', () {
    fakeAsync((async) {
      final c = GameController(paced: false, store: MemoryRecordStore());
      final other = GameController(paced: false, store: MemoryRecordStore());
      async.flushMicrotasks();
      final seed = c.game.dealSeed;
      expect(seed, isNotNull);
      expect(other.game.dealSeed, isNot(seed), reason: 'every game draws its own');
      expect(c.recordText, startsWith('oh2:${seed!.hex}:'));
      final record = SoloRecord.parse(c.recordText)!;
      expect(record.dealSeed, seed);
      expect(record.replay().game.handOf(c.mySeat), c.game.handOf(c.mySeat), reason: 'the record deals the same hand');
      c.newGame();
      async.flushMicrotasks();
      expect(c.game.dealSeed, isNot(seed), reason: 'and a new game draws again');
      c.dispose();
      other.dispose();
    });
  });

  test('a test\'s seed deals the game it always dealt', () {
    fakeAsync((async) {
      final c = GameController(seed: 4, paced: false, store: MemoryRecordStore());
      async.flushMicrotasks();
      expect(c.game.dealSeed, isNull);
      expect(c.recordText, startsWith('oh1:4:'));
      expect(c.game.handOf(c.mySeat), HeartsGame(seed: 4).handOf(c.mySeat));
      c.dispose();
    });
  });
}
