/// A whole simulated table, ready to run: the harness the matrix and
/// the trace tool share.
library;

import 'package:engine/engine.dart';
import '../client.dart';
import '../signing.dart';
import '../spec.dart';
import 'scripted_human.dart';
import 'sim_network.dart';
import 'virtual_clock.dart';

/// A simulated table: [humans] scripted people in the first seats,
/// bots in the rest.
class SimTable {
  SimTable({required this.humans, int seed = 1, int netSeed = 1})
      : clock = VirtualClock(),
        signers = [for (var i = 0; i < humans; i++) FakeSigner('p$i-$seed')] {
    net = SimNetwork(clock, seed: netSeed);
    spec = TableSpec(
      id: 'table-$seed',
      seed: seed,
      seats: [
        for (var s = 0; s < seatCount; s++)
          s < humans ? HumanSeat(signers[s].publicKey) : BotSeat(Persona.roster[(s + seed) % Persona.roster.length]),
      ],
    );
    for (var i = 0; i < humans; i++) {
      final client = TableClient(spec: spec, signer: signers[i], transport: net.attach(signers[i].publicKey), clock: clock);
      people.add(ScriptedHuman(client, net, clock, persona: Persona.roster[(i * 3 + seed) % Persona.roster.length]));
    }
  }

  final int humans;
  final VirtualClock clock;
  final List<FakeSigner> signers;
  late final SimNetwork net;
  late final TableSpec spec;
  final List<ScriptedHuman> people = [];

  Iterable<TableClient> get clients => people.map((p) => p.client);

  /// Clients of people who have not left, crashed or gone quiet, and
  /// have not been removed by the others — a removed client is out of
  /// the table whatever it thinks.
  Iterable<TableClient> get survivors =>
      people.where((p) => !p.gone && p.client.amSeated).map((p) => p.client);

  void start() {
    for (final p in people) {
      p.start();
    }
  }

  /// Runs until every survivor's game is over, or [limitMs] of virtual
  /// time. Returns whether all finished.
  bool run({int limitMs = 3 * 60 * 60 * 1000}) =>
      clock.runUntil(() => survivors.every((c) => c.done), limitMs: limitMs);

  void stop() {
    for (final p in people) {
      p.stop();
      p.client.close();
    }
  }
}
