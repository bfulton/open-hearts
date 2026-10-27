/// A whole simulated table, ready to run: people in the first seats (or
/// the last, with `botsFirst`), bots in the rest, a referee, and the
/// house serving it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'fake_signer.dart';
import 'scripted_human.dart';
import 'sim_deal_worker.dart';
import 'sim_referee.dart';
import 'virtual_clock.dart';

class SimTable {
  SimTable({
    required this.humans,
    int seed = 1,
    int target = gameOverScore,
    this.crypto,
    TableTiming timing = TableTiming.standard,
    bool botsFirst = false,
    bool workers = false,
    this.latencyMs = 30,
    int? houseLatencyMs,
    bool rated = false,
    Map<int, SeatConduct> conducts = const {},
    String? id,
    List<Signer>? keys,
    Signer? houseKey,
    Licence? Function(PublicKey key)? licenceOf,
    this.traces = false,
  }) : clock = VirtualClock() {
    final sealed = crypto != null;
    houseSigner = houseKey ?? FakeSigner('house-$seed');
    referee = SimReferee(clock, house: houseSigner.publicKey);
    signers = keys ?? [for (var i = 0; i < humans; i++) FakeSigner('p$i-$seed')];
    final seats = <SeatHolder>[];
    for (var s = 0; s < seatCount; s++) {
      final person = botsFirst ? s >= seatCount - humans : s < humans;
      seats.add(person
          ? HumanSeat(signers[botsFirst ? s - (seatCount - humans) : s].publicKey,
              licence: licenceOf?.call(signers[botsFirst ? s - (seatCount - humans) : s].publicKey))
          : BotSeat(Persona.roster[(s + seed) % Persona.roster.length]));
    }
    spec = TableSpec(
      id: id ?? 'table-$seed',
      seed: seed,
      seats: seats,
      sealed: sealed,
      target: target,
      timing: timing,
      rated: rated,
      house: sealed ? houseSigner.publicKey : null,
    );
    DealWorker? workerFor() => workers && crypto != null ? SimDealWorker(crypto!, clock) : null;
    _newHouse = () => House(
          signer: houseSigner,
          secret: Uint8List.fromList(utf8.encode('house secret $seed').take(32).toList()),
          lineFor: (_) => referee.line(houseSigner.publicKey, latencyMs: houseLatencyMs ?? latencyMs),
          clock: clock,
          crypto: crypto,
          // The house runs the deal natively, on a server: its slow calls
          // are not a browser's.
          random: Random(seed * 1000 + 999 + _houses++),
          onResult: (result, signed) => results.add(signed),
          onSide: (side) => _watch(side, 'house${_houses > 1 ? '.$_houses' : ''} ${side.role == Role.houseFollower ? 'follower' : 'seat ${side.seat}'}'),
          trace: traces ? (t, l) => _log(l) : null,
        );
    if (sealed) {
      house = _newHouse();
      referee.onStart = (s) => house!.serve(s.id);
    }
    _workerFor = workerFor;
    for (var i = 0; i < humans; i++) {
      final conduct = conducts[i] ?? const SeatConduct();
      _conducts.add(conduct);
      journals.add(TableJournal());
      final line = referee.line(signers[i].publicKey, latencyMs: latencyMs);
      lines.add(line);
      people.add(ScriptedHuman(_watch(_client(i, line, Random(seed * 1000 + i)), 'p$i'), line, clock,
          persona: Persona.roster[(i * 3 + seed) % Persona.roster.length]));
    }
  }

  /// The results the house published, signed, as it published them.
  final List<NostrEvent> results = [];

  /// What each side saw of the table after each entry it took, by side
  /// and entry ([TableRules.settledView]).
  final Map<String, Map<int, String>> views = {};

  TableClient _watch(TableClient c, String name) {
    var side = name;
    for (var k = 2; views.containsKey(side); k++) {
      side = '$name.$k';
    }
    final seen = views[side] = {};
    c.rules.onSettled = (n) => seen[n] = c.rules.settledView();
    return c;
  }

  /// Every entry after which two sides saw the table differently, with
  /// what each saw: none, at a table every side plays by the same rules
  /// from the same log.
  ///
  /// [except] are sides left out: a seat that lies takes its own word
  /// unchecked, so its own view is not the table's.
  List<String> lockstepProblems({int most = 5, Set<String> except = const {}}) {
    final out = <String>[];
    final ns = {for (final v in views.values) ...v.keys}.toList()..sort();
    for (final n in ns) {
      final at = {
        for (final e in views.entries)
          if (e.value.containsKey(n) && !except.contains(e.key.split('.').first)) e.key: e.value[n]!,
      };
      if (at.values.toSet().length <= 1) continue;
      out.add('#$n:\n${[for (final e in at.entries) '  ${e.key}: ${e.value}'].join('\n')}');
      if (out.length >= most) break;
    }
    return out;
  }

  late final DealWorker? Function() _workerFor;
  late final House Function() _newHouse;
  int _houses = 0;
  final List<SeatConduct> _conducts = [];

  TableClient _client(int i, SimLine line, Random random) => TableClient(
        tableId: spec.id,
        signer: signers[i],
        line: line,
        clock: clock,
        spec: spec,
        crypto: crypto,
        dealWorker: _workerFor(),
        journal: journals[i],
        conduct: _conducts[i],
        random: random,
        trace: traces ? (l) => _log('p$i: $l') : null,
      );

  /// What each person's device keeps across a reload, by their place in
  /// [people].
  final List<TableJournal> journals = [];

  /// Person [i]'s device reloaded: the client gone, as closing the tab
  /// is, and after [awayMs] a new one built from what the device kept —
  /// the journal, through its JSON — reading the log from its start.
  ///
  /// [lastWordsLandAfterMs] has what the old client had in flight reach
  /// the referee that long from now, and [latencyMs] gives the new line
  /// its own latency.
  void reload(int i, {int awayMs = 5000, int? lastWordsLandAfterMs, int? latencyMs}) {
    final before = people[i];
    before.stop();
    if (lastWordsLandAfterMs != null) lines[i].closeLeaving(landAfterMs: lastWordsLandAfterMs);
    before.client.close();
    final journal = TableJournal.parse(jsonDecode(jsonEncode(journals[i].toJson())))!;
    journals[i] = journal;
    clock.schedule(awayMs, () {
      final line = referee.line(signers[i].publicKey, latencyMs: latencyMs ?? this.latencyMs);
      lines[i] = line;
      final again = ScriptedHuman(_watch(_client(i, line, Random(spec.seed * 1000 + i + 7919)), 'p$i'), line, clock, persona: before.persona);
      people[i] = again;
      again.start();
    });
  }

  final int humans;
  final DealCrypto? crypto;
  final VirtualClock clock;
  final int latencyMs;
  final bool traces;
  late final SimReferee referee;
  late final TableSpec spec;
  /// The people's keys, by their place in [people]: the simulator's
  /// stand-ins unless real ones were given.
  late final List<Signer> signers;
  late final Signer houseSigner;
  House? house;
  final List<SimLine> lines = [];
  final List<ScriptedHuman> people = [];

  /// Every line the traces said, in order.
  final List<String> trace = [];
  void _log(String l) => trace.add('${clock.nowMs} $l');

  List<TableClient> get clients => [for (final p in people) p.client];

  /// The clients still reading the log: all but those whose app is gone
  /// or whose phone is off the network for good.
  List<TableClient> get following => [for (final p in people) if (p.following) p.client];

  void start() {
    for (final p in people) {
      p.start();
    }
  }

  /// Runs until every client still following has the game over and, at
  /// a sealed table whose house is up, the house's word on it, and the
  /// house has let the table go; or [limitMs] of virtual time.
  bool run({int limitMs = 6 * 60 * 60 * 1000}) => clock.runUntil(
      () =>
          following.every((c) => c.done && (house == null || houseDown || c.rules.result != null)) &&
          (house?.serving.isEmpty ?? true),
      limitMs: limitMs);

  /// Whether the house was taken down ([killHouse]).
  bool houseDown = false;

  /// The house gone: every line it has to the table closed, and nothing
  /// more said for it.
  void killHouse() {
    houseDown = true;
    house?.close();
  }

  /// The house back after [afterMs], as the service is after a restart:
  /// the same key and secret, nothing else, reading the log from its
  /// start.
  void restartHouse({required int afterMs}) {
    house?.close();
    houseDown = true;
    clock.schedule(afterMs, () {
      houseDown = false;
      house = _newHouse()..serve(spec.id);
    });
  }

  void close() {
    for (final p in people) {
      p.stop();
      p.client.close();
    }
    house?.close();
  }
}
