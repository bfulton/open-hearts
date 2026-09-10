// Runs one simulated table and prints where every client stands.
//   dart run --define=HUMANS=3 --define=SEED=52 --define=SPLIT=2 tool/trace.dart
// SPLIT=n partitions the first n humans from the rest for a minute once
// the first hand is over, then heals.
// ignore_for_file: avoid_print
import 'package:table/src/sim/sim.dart';

void main() {
  final humans = int.parse(const String.fromEnvironment('HUMANS', defaultValue: '2'));
  final limit = int.parse(const String.fromEnvironment('LIMIT_MS', defaultValue: '600000'));
  final seed = int.parse(const String.fromEnvironment('SEED', defaultValue: '7'));
  final split = int.parse(const String.fromEnvironment('SPLIT', defaultValue: '0'));
  final t = SimTable(humans: humans, seed: seed);
  final from = int.parse(const String.fromEnvironment('LOG_FROM_MS', defaultValue: '-1'));
  if (from >= 0) {
    for (final c in t.clients) {
      c.log = (line) {
        if (t.clock.nowMs >= from) print(line);
      };
    }
  }
  t.start();
  if (split > 0) {
    t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: limit);
    final keys = t.signers.map((s) => s.publicKey).toList();
    t.net.partition([keys.sublist(0, split).toSet(), keys.sublist(split).toSet()]);
    t.clock.advance(60000);
    print('split for 60 s at ${t.clock.nowMs}; healing');
    for (final c in t.clients) {
      print(c.describe());
    }
    t.net.heal();
  }
  final done = t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: limit);
  print('done=$done at ${t.clock.nowMs} ms; delivered ${t.net.delivered}, dropped ${t.net.dropped}');
  for (final c in t.clients) {
    print(c.describe().trimRight());
    print('    trick ${c.game.trick} record ${c.record.length}');
  }
}
