// Runs one simulated table and prints where every client stands.
//   dart run --define=HUMANS=2 tool/trace.dart
// ignore_for_file: avoid_print
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

void main() {
  final humans = int.parse(const String.fromEnvironment('HUMANS', defaultValue: '2'));
  final limit = int.parse(const String.fromEnvironment('LIMIT_MS', defaultValue: '600000'));
  final clock = VirtualClock();
  final net = SimNetwork(clock, seed: 1);
  final signers = [for (var i = 0; i < humans; i++) FakeSigner('p$i')];
  final spec = TableSpec(id: 't', seed: 7, seats: [
    for (var s = 0; s < seatCount; s++)
      s < humans ? HumanSeat(signers[s].publicKey) : BotSeat(Persona.roster[s]),
  ]);
  final people = [
    for (var i = 0; i < humans; i++)
      ScriptedHuman(
        TableClient(spec: spec, signer: signers[i], transport: net.attach(signers[i].publicKey), clock: clock),
        net, clock, persona: Persona.roster[i]),
  ];
  for (final p in people) {
    p.start();
  }
  final done = clock.runUntil(() => people.every((p) => p.client.done), limitMs: limit);
  print('done=$done at ${clock.nowMs} ms; delivered ${net.delivered}, dropped ${net.dropped}');
  for (final p in people) {
    final c = p.client;
    final g = c.game;
    print('--- ${c.signer.publicKey.substring(0, 6)} seat ${c.mySeat}: hand ${g.handNumber} ${g.phase.name} step ${c.step} '
        'current ${g.currentSeat} trick ${g.trick} pass ${c.awaitingMyPass} play ${c.awaitingMyPlay} pause ${c.pause} '
        'record ${c.record.length} passes ${[for (var s = 0; s < 4; s++) g.passOf(s) != null]}');
  }
}
