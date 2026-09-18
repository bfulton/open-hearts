/// A whole simulated table, ready to run: the harness the matrix and
/// the trace tool share.
library;

import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import '../client.dart';
import '../jury.dart';
import '../signing.dart';
import '../spec.dart';
import 'scripted_human.dart';
import 'sim_juror.dart';
import 'sim_network.dart';
import 'sim_presence.dart';
import 'virtual_clock.dart';

/// A simulated table: [humans] scripted people in the first seats,
/// bots in the rest. With [crypto] the table is sealed: the cards come
/// from the verifiable deal, run for real on the virtual clock.
class SimTable {
  SimTable({
    required this.humans,
    int seed = 1,
    int netSeed = 1,
    int jurors = 0,
    bool lastResort = false,
    int? lastResorts,
    bool withPresence = false,
    this.crypto,
  })  : clock = VirtualClock(),
        signers = [for (var i = 0; i < humans; i++) FakeSigner('p$i-$seed')] {
    net = SimNetwork(clock, seed: netSeed);
    if (jurors > 0 || lastResort || (lastResorts ?? 0) > 0 || withPresence) {
      final p = presence = SimPresence(net, clock);
      for (var j = 0; j < jurors; j++) {
        final juror = SimJuror(FakeSigner('juror$j-$seed'), net, clock, crypto: crypto);
        this.jurors.add(juror);
        p.register(juror);
      }
      // A bench, not one: a table that needs its bot seats held needs
      // [juryToHoldBots] of them, and when it calls there is nobody
      // else to make that up (docs/04-live-play.md).
      final bench = lastResorts ?? (lastResort ? juryToHoldBots : 0);
      for (var b = 0; b < bench; b++) {
        final juror = SimJuror(FakeSigner('last-resort$b-$seed'), net, clock, crypto: crypto);
        this.jurors.add(juror);
        p.register(juror);
        p.lastResorts.add(juror);
      }
    }
    spec = TableSpec(
      id: 'table-$seed',
      seed: seed,
      sealed: crypto != null,
      seats: [
        for (var s = 0; s < seatCount; s++)
          s < humans ? HumanSeat(signers[s].publicKey) : BotSeat(Persona.roster[(s + seed) % Persona.roster.length]),
      ],
    );
    for (var i = 0; i < humans; i++) {
      final client = TableClient(
          spec: spec,
          signer: signers[i],
          transport: net.attach(signers[i].publicKey),
          clock: clock,
          presence: presence,
          crypto: crypto,
          random: Random(seed * 1000 + i));
      people.add(ScriptedHuman(client, net, clock, persona: Persona.roster[(i * 3 + seed) % Persona.roster.length]));
    }
  }

  final int humans;

  /// The deal's primitives, at a sealed table.
  final DealCrypto? crypto;
  final VirtualClock clock;
  final List<FakeSigner> signers;
  late final SimNetwork net;
  late final TableSpec spec;
  final List<ScriptedHuman> people = [];

  /// Strangers online who can be drawn as jurors; the last is the
  /// juror of last resort when there is one.
  final List<SimJuror> jurors = [];
  SimPresence? presence;

  /// Jurors still up: not gone, and not crashed or quiet.
  Iterable<SimJuror> get liveJurors => jurors.where((j) => !j.gone && net.isUp(j.signer.publicKey));

  Iterable<TableClient> get clients => people.map((p) => p.client);

  /// Clients of people who have not left, crashed or gone quiet, and
  /// still seat themselves. A client that applies the record sees its
  /// own removal in it and drops out of here with the rest of the
  /// table; a modified one whose record parted from the table's never
  /// does, and stays a survivor to itself alone. A test with such a
  /// client at the table names the honest set itself rather than ask
  /// here — see the lie tests in sealed_test.dart.
  Iterable<TableClient> get survivors =>
      people.where((p) => !p.gone && p.client.amSeated).map((p) => p.client);

  void start() {
    presence?.start();
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
    for (final j in jurors) {
      j.stop();
    }
  }
}
