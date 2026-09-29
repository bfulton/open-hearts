/// Every one-message change to a short sealed game, one run each.
///
///     cd packages/table && dart run tool/explore.dart --scenario deal
///     dart run tool/explore.dart --scenario leave --shard 1/4 --first
///     dart run tool/explore.dart --scenario leave --fault-at 500,1500,3000
///     dart run tool/explore.dart --scenario deal --census
///     dart run tool/explore.dart --scenario topup --structure
///
/// The chaos walk (`tool/chaos.dart`) throws faults at a table at
/// random, and finds what random faults find: a juror gone, a relay
/// out, loss for a while. What it rarely finds is the other kind —
/// one peer hearing two things in the other order from everybody
/// else, or the one copy of something that mattered not arriving at
/// one peer. Five fixes of that kind were each undone, one at a time,
/// and the walk caught one of them.
///
/// This takes a small sealed game, runs it once to list every event
/// said in its first seconds and every peer it went to (heartbeats
/// aside), and then runs it again once per event, peer and change:
///
/// - **lose**: the first copy of the event to that peer never
///   arrives. Anything said again, carried or caught up gets there
///   later; anything that is not, does not. This is how a turn fails
///   to settle at one peer.
/// - **late**: every copy of the event to that peer arrives
///   [--hold] milliseconds after the first went out — the peer hears
///   it after things said after it. This is how a step comes in
///   before the jury that vouches for it, or a leave after a seat
///   list read without it.
///
/// The simulator is deterministic and the change draws no randomness
/// of its own (SimNetwork.steer), so each run is the baseline with
/// exactly one thing different. The events are tried kind by kind —
/// the jury and the deal first, since that is where these bugs have
/// been, and the plays and witnesses last — and in the order they
/// were said within a kind.
///
/// Each run is held, by default, to what a table owes by the end of
/// its first trick: every survivor dealt in and a trick played within
/// the horizon, no two sides reading different jurors into a bot
/// seat, and every record sound so far. `--whole` plays the one-hand
/// game out instead and asks the whole of it: finished, the same
/// record everywhere, verifying complete. It is three times the time
/// a run, and catches what only shows at the audit.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

/// A game to explore: how it is built, what it does to itself on the
/// way, and how long it has.
class Scenario {
  const Scenario(this.about, this.build,
      {this.script, this.faultAt = 0, this.windowMs = 20000, this.horizonMs = 5 * 60 * 1000, this.whole = false});
  final String about;
  final SimTable Function(DealCrypto crypto) build;
  /// What the game does to itself, at [at] milliseconds.
  final void Function(SimTable t, int at)? script;

  /// When the scripted fault comes, unless `--fault-at` says otherwise.
  final int faultAt;

  /// Played out and judged whole, whatever `--whole` says: a scenario
  /// whose point comes after the first trick.
  final bool whole;

  /// Events first said before this are the ones changed.
  final int windowMs;

  /// And the table has this long, from the start, to get there.
  final int horizonMs;
}

SimTable _relayPaced(SimTable t) {
  // A relay's latency rather than a data channel's: a message in
  // flight long enough for another to pass it.
  t.net.minLatencyMs = 200;
  t.net.maxLatencyMs = 400;
  return t;
}

final scenarios = <String, Scenario>{
  'deal': Scenario(
    'one person and three bot seats the jury holds: every bot step of the deal is a juror\'s',
    (crypto) => _relayPaced(SimTable(humans: 1, seed: 4, crypto: crypto, jurors: jurySize, target: 1)),
  ),
  'two': Scenario(
    'two people, two held bot seats, a jury with two to spare',
    (crypto) => _relayPaced(SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1)),
  ),
  'leave': Scenario(
    'three people, one of whom leaves during the deal',
    (crypto) => _relayPaced(SimTable(humans: 3, seed: 12, crypto: crypto, jurors: jurySize, target: 1)),
    script: (t, at) => t.clock.schedule(at, () => t.people[2].depart(Exit.leave)),
    faultAt: 3000,
  ),
  'summons': Scenario(
    'one person and three held seats, the jurors hearing their summons late — by the fault time',
    (crypto) => _relayPaced(SimTable(humans: 1, seed: 4, crypto: crypto, jurors: jurySize, target: 1)),
    // Not a message on the network, so no change to one can move it:
    // the summons goes by presence, and a juror summoned late is the
    // one that holds a hand's first steps before it has a deal to put
    // them in.
    script: (t, at) => t.presence!.summonsMs = at,
    faultAt: 50,
  ),
  'topup': Scenario(
    'two people; two jurors holding no seat go quiet during the deal, and the jury is topped up while it deals',
    (crypto) => _relayPaced(SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1)),
    script: (t, at) => t.clock.schedule(at, () {
      final c = t.clients.first;
      final drawn = c.juries.isEmpty ? const <PublicKey>[] : c.juries.first.event.jurors;
      // Two that hold no seat. A holder that goes during the deal takes
      // the hand with it (_carryEscrow), which is its own case and
      // would leave no top-up to watch.
      final held = c.botHolders(c.game.handNumber).values.toSet();
      for (final k in drawn.where((k) => !held.contains(k)).take(2)) {
        t.net.goOffline(k);
      }
    }),
    faultAt: 2500,
    // A jury is judged short thirty seconds after it goes quiet, so
    // the top-up comes well after the first trick.
    windowMs: 45000,
    whole: true,
  ),
};

/// Most likely to matter first, a kind not named last. What changes
/// who is who — a jury, a top-up, somebody leaving or put out — is the
/// rarest traffic and moves the most when it lands late; then the
/// protocol's own steps; then the routine: a juror saying it serves,
/// the plays, and the witnesses to them, which are most of the rest.
const _kindOrder = ['jury', 'topup', 'leave', 'boot', 'absent', 'deal', 'release', 'appeal', 'verdict', 'serve', 'pass', 'play', 'witness'];

/// One event to one peer, as the baseline said it.
class Target {
  Target(this.id, this.to, this.from, this.atMs, this.message);
  final String id;
  final PublicKey to;
  final PublicKey from;
  final int atMs;
  final Map<String, Object?> message;

  String get kind => '${message['kind']}';

  @override
  String toString() {
    final body = message['body'];
    final what = body is Map
        ? [
            for (final k in ['hand', 'turn', 'seat', 'round', 'about'])
              if (body[k] != null) '$k ${body[k]}',
          ].join(' ')
        : '';
    return '$kind ${from.substring(0, 4)}→${to.substring(0, 4)} first said at ${atMs}ms $what';
  }
}

enum Change { lose, late }

/// Runs [s] once with [change] made to [target], and says what the
/// table owed and did not do; null when it held. [seen] collects the
/// targets, for the baseline; [trace] prints every client's.
String? runOnce(Scenario s, DealCrypto crypto,
    {Target? target,
    Change? change,
    int holdMs = 2500,
    bool whole = false,
    List<Target>? seen,
    bool trace = false,
    int? faultAt,
    StructureLog? structure}) {
  final t = s.build(crypto);
  // Read every second, and once more at the end: what each side waits
  // for against who can end it (lib/src/sim/structure.dart).
  if (structure != null) {
    void read() {
      structure.take(t);
      t.clock.schedule(1000, read);
    }

    t.clock.schedule(1000, read);
  }
  if (trace) {
    for (final c in t.clients) {
      c.log = print;
    }
    // A juror's client is made when its summons comes, so it is looked
    // for again every second.
    void jurors() {
      for (final j in t.jurors) {
        j.client?.log ??= print;
      }
      t.clock.schedule(1000, jurors);
    }

    t.clock.schedule(1, jurors);
  }
  final met = <String>{};
  var lost = false;
  t.net.steer = (from, to, message) {
    final kind = message['kind'];
    if (kind == 'heartbeat') return null;
    final id = '${message['id']}';
    if (seen != null && t.clock.nowMs < s.windowMs && met.add('$id|$to')) {
      seen.add(Target(id, to, from, t.clock.nowMs, message));
    }
    if (target == null || id != target.id || to != target.to) return null;
    if (change == Change.lose) {
      if (lost) return null;
      lost = true;
      return -1;
    }
    // Late: held until the same moment every time, so a copy said
    // again before then arrives no sooner than the first.
    final until = target.atMs + holdMs;
    return t.clock.nowMs < until ? until - t.clock.nowMs : null;
  };
  try {
    // Before the start, so a script can set up as well as schedule.
    s.script?.call(t, faultAt ?? s.faultAt);
    t.start();
    if (whole) {
      t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: s.horizonMs);
      structure?.take(t);
      return judgeWhole(t, s);
    }
    bool pastFirstTrick(TableClient c) => c.done || (c.game.phase == Phase.playing && c.game.tricksPlayed >= 1) || c.game.handNumber > 0;
    t.clock.runUntil(() => t.survivors.every(pastFirstTrick), limitMs: s.horizonMs);
    // A moment more, for the last of the first trick to reach everyone.
    t.clock.advance(3000);
    structure?.take(t);
    return judgeDealt(t, s, pastFirstTrick);
  } finally {
    t.stop();
  }
}

String? judgeDealt(SimTable t, Scenario s, bool Function(TableClient) pastFirstTrick) {
  final survivors = t.survivors.toList();
  if (survivors.isEmpty) return 'nobody left at the table';
  for (final c in survivors) {
    if (!pastFirstTrick(c)) return 'not through the first trick in ${s.horizonMs ~/ 1000} s:\n${c.describe()}';
  }
  final apart = disagreed(t);
  if (apart != null) return apart;
  for (final c in survivors) {
    final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries, crypto: t.crypto, releases: c.releases);
    if (!v.ok) return 'a record unsound so far: ${v.reason}';
  }
  return null;
}

String? judgeWhole(SimTable t, Scenario s) {
  final survivors = t.survivors.toList();
  if (survivors.isEmpty) return 'nobody left at the table';
  for (final c in survivors) {
    if (!c.done) return 'not finished in ${s.horizonMs ~/ 1000} s:\n${c.describe()}';
  }
  final first = survivors.first.record.map((d) => d.key).toList();
  for (final c in survivors.skip(1)) {
    final r = c.record.map((d) => d.key).toList();
    if (r.length != first.length || Iterable.generate(r.length).any((i) => r[i] != first[i])) {
      return 'survivors hold different records';
    }
  }
  for (final c in survivors) {
    final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: t.crypto, releases: c.releases);
    if (!(v.ok && v.complete)) return 'a finished record that does not verify complete: ${v.reason}';
  }
  return disagreed(t);
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf('--$name');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> main(List<String> args) async {
  final name = _arg(args, 'scenario') ?? 'deal';
  final s = scenarios[name];
  if (s == null) {
    print('scenarios: ${scenarios.keys.join(', ')}');
    exit(2);
  }
  // One hold or several: `--hold 2500,6000` tries each copy late by
  // each. A juror holds its keys back two seconds on purpose, so a
  // jury that is to arrive after them has to be held back longer.
  final holds = [for (final h in (_arg(args, 'hold') ?? '2500').split(',')) int.parse(h)];
  final holdMs = holds.first;
  final shard = (_arg(args, 'shard') ?? '0/1').split('/').map(int.parse).toList();
  final limit = int.tryParse(_arg(args, 'limit') ?? '');
  final whole = args.contains('--whole') || s.whole;
  final stopAtFirst = args.contains('--first');
  final changes = [for (final c in (_arg(args, 'changes') ?? 'lose,late').split(',')) Change.values.byName(c)];
  // What each run does to its copy: lost, or late by each hold.
  final tries = [
    for (final c in changes)
      if (c == Change.lose) (change: c, hold: 0) else ...[for (final h in holds) (change: c, hold: h)],
  ];
  // Remembered across runs: each is the baseline with one thing
  // different, so most of its cryptography is the baseline's too.
  final crypto = MemoCrypto(await DealCrypto.load());
  final started = DateTime.now();
  String secs() => (DateTime.now().difference(started).inMilliseconds / 1000).toStringAsFixed(1);

  // When the scenario's own fault comes: `--fault-at 1000,3000,5000`
  // walks each. A fault is the one thing a single-message change
  // cannot move, and some faults matter only at a moment — a leave
  // that lands while the deal is being built, and not after its keys.
  final faultTimes = [for (final x in (_arg(args, 'fault-at') ?? '${s.faultAt}').split(',')) int.parse(x)];
  print('$name: ${s.about}');

  var runs = 0;
  var broke = 0;
  // `--structure`: each run read every second against who can end each
  // wait. Counts runs with each kind of finding; prints the first run
  // of each kind. Measures; decides nothing.
  final measure = args.contains('--structure');
  final runsWith = <String, int>{};
  final runsEndedWith = <String, int>{};
  final runsEndedOnline = <String, int>{};
  void tally(StructureLog log, String what) {
    for (final kind in log.standing.keys) {
      runsEndedWith[kind.name] = (runsEndedWith[kind.name] ?? 0) + 1;
    }
    for (final kind in log.standingOnline.keys) {
      runsEndedOnline[kind.name] = (runsEndedOnline[kind.name] ?? 0) + 1;
    }
    // Every run with something still read among sides online when it
    // ended, each named so it can be replayed (`--match`).
    for (final e in log.seen.values) {
      if (e.last != log.lastTaken || e.finding.cutOff) continue;
      print('still read at the end, run $runs, $what\n  ${e.finding} (${e.first} to ${e.last} ms)');
    }
    for (final kind in log.counts.keys) {
      final n = runsWith[kind.name] = (runsWith[kind.name] ?? 0) + 1;
      if (n == 1) {
        final e = log.seen.values.firstWhere((e) => e.finding.what == kind);
        print('first ${kind.name}: run $runs, $what\n  ${e.finding} (${e.first} to ${e.last} ms)');
      }
    }
  }
  // Every fault time's baseline first, a run each: at the wrong moment
  // the fault alone may be enough.
  final baselines = <int, List<Target>>{};
  for (final f in faultTimes) {
    final targets = baselines[f] = <Target>[];
    runs++;
    final baseLog = measure ? StructureLog() : null;
    final base = runOnce(s, crypto, whole: whole, seen: targets, faultAt: f, structure: baseLog);
    print('fault at ${f}ms: baseline ${base == null ? 'held' : 'BROKE: $base'}; '
        '${targets.length} event-to-peer pairs in the first ${s.windowMs ~/ 1000} s (${secs()} s)');
    if (baseLog != null) {
      // With nothing changed: what every run below starts from.
      String counts(Map<Enum, int> m) => m.isEmpty ? 'nothing' : m.entries.map((e) => '${e.key.name} ${e.value}').join(', ');
      print('  baseline structure: ${counts(baseLog.counts)}; at the end ${counts(baseLog.standing)} '
          '(${counts(baseLog.standingOnline)} among sides online)');
      final shown = <Enum>{};
      for (final e in baseLog.seen.values) {
        if (shown.add(e.finding.what)) print('    ${e.finding} (${e.first} to ${e.last} ms)');
      }
      final standing = baseLog.seen.values.where((e) => e.last == baseLog.lastTaken).toList();
      if (standing.isNotEmpty) print('  still there at the end:');
      for (final e in standing.take(12)) {
        print('    ${e.finding} (from ${e.first} ms)');
      }
      if (standing.length > 12) print('    and ${standing.length - 12} more');
    }
    if (base == null) continue;
    broke++;
    if (stopAtFirst) {
      print('first break after $runs run(s), ${secs()} s');
      exit(1);
    }
  }
  int rank(Target t) {
    final i = _kindOrder.indexOf(t.kind);
    return i < 0 ? _kindOrder.length : i;
  }

  for (final f in faultTimes) {
    // Kind by kind, then as said. A stable sort keeps the second.
    final order = List.of(baselines[f]!)..sort((a, b) => rank(a).compareTo(rank(b)));
    if (args.contains('--census')) {
      final byKind = <String, int>{};
      for (final t in order) {
        byKind[t.kind] = (byKind[t.kind] ?? 0) + 1;
      }
      print('by kind: ${byKind.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
      continue;
    }

    // One run again, with every client's trace: `--at 693 --changes
    // lose` repeats the run the sweep numbered 1387 (two changes an
    // event, counted from one); `--match 'witness aeaa→6eab first said
    // at 308ms'` the same one by what it was, which outlives a change
    // to the code — a fix that alters the traffic renumbers everything
    // after it.
    final match = _arg(args, 'match');
    final at = match != null ? order.indexWhere((t) => '$t'.contains(match)) : int.tryParse(_arg(args, 'at') ?? '');
    if (match != null && at == -1) {
      print('no event matches "$match"');
      exit(2);
    }
    if (at != null) {
      print('replaying ${order[at]}, ${changes.single.name}');
      final why = runOnce(s, crypto,
          target: order[at], change: changes.single, holdMs: holdMs, whole: whole, trace: true, faultAt: f);
      print('=== ${why ?? 'held'}');
      exit(why == null ? 0 : 1);
    }

    for (var i = 0; i < order.length; i++) {
      if (i % shard[1] != shard[0]) continue;
      for (final (:change, :hold) in tries) {
        if (limit != null && runs >= limit) break;
        runs++;
        final log = measure ? StructureLog() : null;
        final why = runOnce(s, crypto, target: order[i], change: change, holdMs: hold, whole: whole, faultAt: f, structure: log);
        if (log != null) tally(log, '${order[i]}, ${change == Change.lose ? 'first copy lost' : 'held ${hold}ms'}');
        if (runs % 25 == 0) {
          final asked = crypto.hits + crypto.misses;
          print('$runs runs (${secs()} s), up to ${order[i].kind}; '
              '${asked == 0 ? 0 : (100 * crypto.hits / asked).round()}% of the cryptography from memory');
        }
        if (why == null) continue;
        broke++;
        print('run $runs (${secs()} s): fault at ${f}ms, ${order[i]}, '
            '${change == Change.lose ? 'its first copy lost' : 'held ${hold}ms'}\n  $why');
        if (stopAtFirst) {
          print('first break after $runs run(s), ${secs()} s');
          exit(1);
        }
      }
    }
  }
  if (args.contains('--census')) exit(0);
  if (measure) {
    print('structure: ${runsWith.isEmpty ? 'nothing found' : runsWith.entries.map((e) => '${e.key} in ${e.value} run(s), '
        'still there at the end of ${runsEndedWith[e.key] ?? 0} (${runsEndedOnline[e.key] ?? 0} among sides online)').join('; ')}');
  }
  print('$runs runs in ${secs()} s: ${broke == 0 ? 'every one held' : '$broke broke'}');
  exit(broke == 0 ? 0 : 1);
}
