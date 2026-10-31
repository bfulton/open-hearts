/// A pool's tag, and what the house takes it to name (matching.dart).
library;

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('every pool a device can wait in is one the house can seat, named the one way it is named', () {
    for (final pool in pools) {
      for (var target = 1; target <= longGameScore; target++) {
        expect(poolOf(poolTag(pool, target: target)), (pool: pool, target: target), reason: '$pool to $target');
      }
    }
    expect(poolTag('rated'), 'queue:rated', reason: 'the game to fifty has the plain tag');
  });

  test('and nothing else is a pool', () {
    for (final tag in [
      'queue:rated:50', // the game's own score, which the plain tag names
      'queue:rated:050',
      'queue:rated:0',
      'queue:rated:101',
      'queue:rated:-1',
      'queue:rated:x',
      'queue:rated:100:1',
      'queue:ranked',
      'queue:',
      'ROOM42',
      'ab' * 16,
    ]) {
      expect(poolOf(tag), isNull, reason: tag);
    }
  });
}
