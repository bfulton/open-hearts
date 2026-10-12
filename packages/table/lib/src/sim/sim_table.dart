/// A whole simulated table, ready to run: the harness the matrix and
/// the trace tool share.
library;

import 'dart:convert';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import '../client.dart';
import '../journal.dart';
import '../jury.dart';
import '../licence.dart';
import '../signing.dart';
import '../spec.dart';
import '../time_bank.dart';
import '../timing.dart';
import 'scripted_human.dart';
import 'sim_deal_worker.dart';
import 'sim_juror.dart';
import 'sim_network.dart';
import 'sim_presence.dart';
import 'virtual_clock.dart';

/// A simulated table: [humans] scripted people in the first seats,
/// bots in the rest — or the bots first, with `botsFirst`. With
/// [crypto] the table is sealed: the cards come from the verifiable
/// deal, run for real on the virtual clock; with `workers` as well,
/// each device makes the deal's slow calls in a worker of its own
/// that takes a browser's time over them ([SimDealWorker]), where
/// otherwise they take none. With `sweepJurors` a
/// juror lets go of the table once it has served, as the duty does,
/// and a later summons starts it again from the first hand.
class SimTable {
  SimTable({
    required this.humans,
    int seed = 1,
    int netSeed = 1,
    int jurors = 0,
    bool lastResort = false,
    int? lastResorts,
    bool withPresence = false,
    int target = gameOverScore,
    this.crypto,
    TableTiming timing = TableTiming.standard,
    TimeBank? timeBank,
    bool botsFirst = false,
    bool sweepJurors = false,
    bool workers = false,
    String? id,
    List<Signer>? keys,
    Map<int, TableJournal>? journals,
    Licence? Function(PublicKey key)? licenceOf,
  })  : journals = journals ?? {},
        clock = VirtualClock(),
        // Fake keys unless told otherwise: a table played for a record
        // a real device will check needs real signatures.
        signers = keys ?? [for (var i = 0; i < humans; i++) FakeSigner('p$i-$seed')] {
    net = SimNetwork(clock, seed: netSeed);
    SimDealWorker? workerFor(PublicKey key) {
      final c = crypto;
      if (!workers || c == null) return null;
      return dealWorkers[key] = SimDealWorker(c, clock);
    }

    if (jurors > 0 || lastResort || (lastResorts ?? 0) > 0 || withPresence) {
      final p = presence = SimPresence(net, clock);
      for (var j = 0; j < jurors; j++) {
        final signer = FakeSigner('juror$j-$seed');
        final juror = SimJuror(signer, net, clock, crypto: crypto, dealWorker: workerFor(signer.publicKey))..sweeps = sweepJurors;
        this.jurors.add(juror);
        p.register(juror);
      }
      // Several backup jurors, not one: a table that needs its bot
      // seats held needs [juryToHoldBots] of them, and when it calls too
      // few others are online to make that up (docs/explanation/live-play.md).
      final bench = lastResorts ?? (lastResort ? juryToHoldBots : 0);
      for (var b = 0; b < bench; b++) {
        final signer = FakeSigner('last-resort$b-$seed');
        final juror = SimJuror(signer, net, clock, crypto: crypto, dealWorker: workerFor(signer.publicKey))..sweeps = sweepJurors;
        this.jurors.add(juror);
        p.register(juror);
        p.lastResorts.add(juror);
      }
    }
    spec = TableSpec(
      id: id ?? 'table-$seed',
      seed: seed,
      sealed: crypto != null,
      target: target,
      timing: timeBank == null ? timing : timing.withBank(timeBank),
      seats: [
        for (var s = 0; s < seatCount; s++)
          if (botsFirst ? s >= seatCount - humans : s < humans)
            HumanSeat(signers[botsFirst ? s - (seatCount - humans) : s].publicKey,
                licence: licenceOf?.call(signers[botsFirst ? s - (seatCount - humans) : s].publicKey))
          else
            BotSeat(Persona.roster[(s + seed) % Persona.roster.length]),
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
          dealWorker: workerFor(signers[i].publicKey),
          journal: this.journals[i],
          random: Random(seed * 1000 + i));
      people.add(ScriptedHuman(client, net, clock, persona: Persona.roster[(i * 3 + seed) % Persona.roster.length]));
    }
  }

  final int humans;

  /// Journals for the people who keep one, by their place in [people]:
  /// what a person's device needs to come back after a reload
  /// ([TableJournal], [reload]).
  final Map<int, TableJournal> journals;

  /// Person [i]'s page reloaded: the process gone at once, as a tab
  /// closing is, and after [awayMs] a new client built from the journal
  /// alone, on a new link, with nothing else of the old one.
  void reload(int i, {int awayMs = 5000, Random? random}) {
    final old = people[i];
    final key = old.client.signer.publicKey;
    net.crash(key);
    old.stop();
    old.client.close();
    old.gone = true;
    clock.advance(awayMs);
    net.revive(key);
    final journal = TableJournal.parse(jsonDecode(jsonEncode(journals[i]!.toJson())))!;
    journals[i] = journal;
    final client = TableClient(
        spec: spec,
        signer: old.client.signer,
        transport: net.attach(key),
        clock: clock,
        presence: presence,
        crypto: crypto,
        dealWorker: dealWorkers[key],
        journal: journal,
        random: random ?? Random(i + 7919));
    people[i] = ScriptedHuman(client, net, clock, persona: old.persona)..start();
  }

  /// The deal's primitives, at a sealed table.
  final DealCrypto? crypto;

  /// Each device's deal worker, by its key, when the table has them.
  final Map<PublicKey, SimDealWorker> dealWorkers = {};
  final VirtualClock clock;
  final List<Signer> signers;
  late final SimNetwork net;
  late final TableSpec spec;
  final List<ScriptedHuman> people = [];

  /// Strangers online who can be drawn as jurors; the last is the
  /// backup juror when there is one.
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
