/// Replays a solo game record and prints every trick.
///
///     cd packages/engine && dart run tool/replay.dart 'oh1:…'
///
/// The record is the line the app's Copy button produces; it holds the
/// seed, the bots, and the human's own choices, and everything else is
/// recomputed. Moon hands are flagged, since they are the usual reason
/// to look.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'package:engine/engine.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    print('usage: dart run tool/replay.dart <record>');
    return;
  }
  final record = SoloRecord.parse(args.first);
  if (record == null) {
    print('not a record');
    return;
  }
  final names = [for (var s = 0; s < seatCount; s++) s == record.humanSeat ? 'You' : record.personas[s]];
  print('seed ${record.seed}: ${names.join(', ')}${record.target == gameOverScore ? '' : ', to ${record.target}'}');
  final replay = record.replay();
  for (final h in replay.hands) {
    final moon = h.moonShooter == null ? '' : '   ← ${names[h.moonShooter!]} shot the moon';
    print('\nhand ${h.index + 1}: scores ${h.scores}$moon');
    if (h.humanPass.isNotEmpty) print('  you passed ${h.humanPass.join(' ')}');
    for (var t = 0; t < h.tricks.length; t++) {
      final trick = h.tricks[t];
      final winner = trickWinner(trick);
      print('  ${(t + 1).toString().padLeft(2)}: ${trick.map((p) => '${names[p.seat]}:${p.card}').join('  ')}'
          '   → ${names[winner]}');
    }
  }
  print('\n${replay.complete ? 'final' : 'so far'}: ${replay.game.totals}');
}
