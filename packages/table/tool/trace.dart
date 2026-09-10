// Replays a scenario and prints where every client stands, with a
// transition log from LOG_FROM_MS on.
//
//   dart run --define=CHAOS=27 --define=LOG_FROM_MS=70000 tool/trace.dart
//   dart run --define=HUMANS=2 --define=DEPART=0:idle:mid-trick tool/trace.dart
//   dart run --define=HUMANS=4 --define=SPLIT=2 --define=SPLIT_MS=60000 tool/trace.dart
//
// DEPART is seat:exit:moment, comma-separated for several; moments are
// the names in Moment.all.
// ignore_for_file: avoid_print
import 'package:table/src/sim/sim.dart';

void main() {
  final from = int.parse(const String.fromEnvironment('LOG_FROM_MS', defaultValue: '-1'));
  const chaos = String.fromEnvironment('CHAOS');
  const depart = String.fromEnvironment('DEPART');
  final humans = int.parse(const String.fromEnvironment('HUMANS', defaultValue: '2'));
  final seed = int.parse(const String.fromEnvironment('SEED', defaultValue: '1'));
  final split = int.parse(const String.fromEnvironment('SPLIT', defaultValue: '0'));
  final splitMs = int.parse(const String.fromEnvironment('SPLIT_MS', defaultValue: '60000'));

  void attachLog(SimTable t) {
    if (from < 0) return;
    for (final c in t.clients) {
      c.log = (line) {
        if (t.clock.nowMs >= from) print(line);
      };
    }
  }

  void report(SimTable t, {String? faults}) {
    if (faults != null) print('faults: $faults');
    print('now ${t.clock.nowMs} ms; delivered ${t.net.delivered}, dropped ${t.net.dropped}');
    for (final c in t.clients) {
      print(c.describe().trimRight());
      print('    gone ${t.people.firstWhere((p) => p.client == c).gone} record ${c.record.length} trick ${c.game.trick}');
    }
  }

  if (chaos.isNotEmpty) {
    final sc = ChaosScenario(int.parse(chaos));
    attachLog(sc.table);
    sc.table.start();
    sc.schedule();
    sc.table.clock.advanceTo(sc.quietAt);
    print('--- faults over; quiet');
    report(sc.table, faults: sc.faults.join('; '));
    sc.quiet();
    sc.table.run();
    print('--- end');
    report(sc.table);
    return;
  }

  final departures = <Departure>[
    for (final d in depart.split(',').where((x) => x.isNotEmpty))
      Departure(
        int.parse(d.split(':')[0]),
        Exit.values.byName(d.split(':')[1]),
        Moment.all.firstWhere((m) => m.name == d.split(':')[2]),
      ),
  ];
  final cell = MatrixCell(humans: humans, departures: departures, seed: seed, partitionFirst: split, partitionMs: splitMs);
  attachLog(cell.table);
  cell.run(beforeHeal: (t) {
    print('--- healing');
    report(t);
  });
  print('--- end');
  report(cell.table);
}
