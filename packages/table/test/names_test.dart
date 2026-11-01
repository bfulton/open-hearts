/// Names made fit to show (names.dart): what a device says it is
/// called, without what is not text, and no longer than a name is kept.
library;

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('a name keeps its text and loses what is not text, trimmed', () {
    expect(cleanName('  Ada Lovelace '), 'Ada Lovelace');
    expect(cleanName('A\nda\u0000\u0085'), 'Ada', reason: 'control characters');
    expect(cleanName('José 😀 Zoë'), 'José 😀 Zoë');
    expect(cleanName('👩\u200d👩\u200d👧'), '👩\u200d👩\u200d👧', reason: 'the joiner is part of the emoji');
    expect(cleanName('محمد'), 'محمد', reason: 'a name written right to left is still a name');
  });

  test('a name loses the characters that change the direction text is drawn in', () {
    // An override left open draws "kcuf wins" as "sniw fuck": the word
    // the filter refuses, and the sentence round it backwards.
    expect(cleanName('\u202ekcuf'), 'kcuf');
    expect(cleanName('Bob\u202e'), 'Bob');
    for (final c in [0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069, 0x200e, 0x200f, 0x061c]) {
      expect(cleanName('A${String.fromCharCode(c)}da'), 'Ada', reason: c.toRadixString(16));
    }
  });

  test('a name is no longer than a name is kept, counted in characters', () {
    expect(cleanName('x' * 500), 'x' * longestName);
    expect(cleanName('😀' * 100), '😀' * longestName, reason: 'an emoji is one character, never half of one');
    expect(cleanName('abcdef', most: 3), 'abc');
  });

  test('a watched table\'s names are read as they may be shown', () {
    final view = WatchedTable(
      table: 'x',
      target: 50,
      seq: 3,
      hand: 0,
      phase: Phase.playing,
      names: const ['\u202ekcuf', 'Bao', 'Cy\u2066', ' Dee '],
      totals: const [0, 0, 0, 0],
      taken: const [0, 0, 0, 0],
      plays: const [],
    ).toJson();
    expect(WatchedTable.parse(view, table: 'x')!.names, ['kcuf', 'Bao', 'Cy', 'Dee']);
  });
}
