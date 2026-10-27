/// A random walk through what can go wrong at a refereed table, one seed
/// each: a table of one to four people, sealed or not, and faults thrown
/// at it as it plays — people going every way at every moment, devices
/// reloaded, sockets dropping, phones off the network for a while, a
/// slow line, the house restarted, a seat that lies — and every
/// invariant of the table checked when it is over. Deterministic: a
/// seed that broke once breaks again (docs/how-to/run-the-chaos-walk.md).
library;

import 'dart:convert';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'lies.dart';
import 'scripted_human.dart';
import 'sim_table.dart';

/// Null when every invariant held at [seed]; what broke, and the faults
/// that led there, when one did not. [crypto] runs it sealed; [workers]
/// makes the deal's slow calls in a worker that takes a browser's time.
/// [tally] counts what the walks did: how games ended, how seats were
/// given up, the faults thrown.
String? walkChaos(int seed, {DealCrypto? crypto, bool workers = false, bool traces = false, Map<String, int>? tally}) {
  void count(String what) {
    if (tally != null) tally[what] = (tally[what] ?? 0) + 1;
  }

  final r = Random(seed);
  final sealed = crypto != null;
  final humans = 1 + r.nextInt(4);
  final faults = <String>[];
  final conducts = <int, SeatConduct>{};
  if (sealed && humans > 1 && r.nextInt(5) == 0) {
    final liar = r.nextInt(humans);
    final lie = [Lie.declare, Lie.withhold][r.nextInt(2)];
    conducts[liar] = lie;
    faults.add('p$liar lies: ${lie.name}');
  }
  final slowHouse = sealed && r.nextInt(5) == 0 ? 1000 + r.nextInt(5000) : null;
  if (slowHouse != null) faults.add('the house ${slowHouse}ms away');
  final t = SimTable(
    humans: humans,
    seed: seed,
    crypto: crypto,
    target: r.nextBool() ? 26 : gameOverScore,
    botsFirst: r.nextBool(),
    workers: workers,
    latencyMs: 10 + r.nextInt(150),
    houseLatencyMs: slowHouse,
    conducts: conducts,
    traces: traces,
  );
  final silence = t.spec.timing.silenceMs;

  // What may take a person's seat: a way of going, a long silence, a
  // lie told and found out.
  final mayLose = <int>{};
  final mayLeave = <int>{};
  for (var i = 0; i < humans; i++) {
    final p = t.people[i];
    if (r.nextInt(5) < 2) {
      final going = Going.values[r.nextInt(Going.values.length)];
      final moments = [for (final m in Moment.all) if (sealed || m != Moment.duringDeal) m];
      final m = moments[r.nextInt(moments.length)];
      final at = Moment(m.name, m.holds, fromHand: r.nextInt(3));
      p
        ..going = going
        ..goAt = at;
      if (going == Going.offline) {
        p.backAfterMs = [null, silence ~/ 2, silence + 15000][r.nextInt(3)];
      }
      mayLose.add(i);
      if (going == Going.leave) mayLeave.add(i);
      faults.add('p$i goes by ${going.name} ${at.name} from hand ${at.fromHand}'
          '${going == Going.offline ? ', back ${p.backAfterMs == null ? 'never' : 'after ${p.backAfterMs}ms'}' : ''}');
    }
    if (conducts[i] == Lie.declare) mayLose.add(i);
    if (r.nextInt(5) == 0) {
      final at = 5000 + r.nextInt(300000);
      final away = 1000 + r.nextInt(14000);
      faults.add('p$i reloads at ${at}ms, away ${away}ms');
      t.clock.schedule(at, () => t.reload(i, awayMs: away));
    }
    for (var k = r.nextInt(4); k > 0; k--) {
      final at = 2000 + r.nextInt(400000);
      final back = 300 + r.nextInt(5000);
      faults.add('p$i\'s socket drops at ${at}ms, back after ${back}ms');
      t.clock.schedule(at, () {
        t.lines[i]
          ..reconnectMs = back
          ..drop();
      });
    }
  }
  if (sealed && r.nextInt(5) == 0) {
    final at = 10000 + r.nextInt(300000);
    final away = 1000 + r.nextInt(t.spec.timing.houseGraceMs ~/ 2);
    faults.add('the house restarts at ${at}ms, away ${away}ms');
    t.clock.schedule(at, () => t.restartHouse(afterMs: away));
  }

  for (final f in faults) {
    count('fault: ${f.replaceAll(RegExp(r'p\d'), 'p').replaceAll(RegExp(r' (at|after|from hand) \S+'), '').replaceAll(RegExp(r', away \S+'), '').replaceAll(RegExp(r'\d+ms'), 'n')}');
  }
  String broke(String what) => '$what\n  faults: ${faults.isEmpty ? 'none' : faults.join('; ')}'
      '${traces ? '\n${t.trace.skip(max(0, t.trace.length - 60)).join('\n')}' : ''}';

  t.start();
  try {
    if (!t.run(limitMs: 8 * 60 * 60 * 1000)) {
      return broke('the game did not end: ${[for (final c in t.following) c.rules.describe()].join(' / ')}');
    }
    final liars = {for (final e in conducts.entries) if (e.value == Lie.declare) e.key};
    final problem = tableProblems(t, mayLose: mayLose, mayLeave: mayLeave, liars: liars, count: count);
    return problem == null ? null : broke(problem);
  } catch (e, st) {
    return broke('threw: $e\n${st.toString().split('\n').take(8).join('\n')}');
  } finally {
    t.close();
  }
}

/// What is wrong with [t] once it has run, or null: every side that
/// still reads the log saw the same table after every entry and came to
/// the same end; anyone reading the log alone comes there too; the game
/// is over as the faults allow; nobody but [mayLose] lost a seat, nobody
/// but [mayLeave] left and nobody but [liars] was found to lie; nothing
/// was said twice; and at a sealed table the house's word on the end is
/// in the log and true.
String? tableProblems(SimTable t,
    {Set<int> mayLose = const {}, Set<int> mayLeave = const {}, Set<int> liars = const {}, void Function(String what)? count}) {
  // Every side that still reads the log saw the same table after every
  // entry, and came to the same end.
  final lockstep = t.lockstepProblems(most: 1);
  if (lockstep.isNotEmpty) return 'sides saw different tables: ${lockstep.single}';
  final following = t.following;
  final sealed = t.spec.sealed;
  final crypto = t.crypto;
  final log = t.referee.log;
  final first = following.isEmpty ? null : following.first.rules;
  for (final c in following) {
    if (c.rules.endHash != first!.endHash || c.state != first.state || c.game.totals.join() != first.game.totals.join()) {
      return 'seat ${c.mySeat} ended elsewhere: ${c.rules.describe()} against ${first.describe()}';
    }
  }
  // Anyone at all, from the log alone, comes to the same end.
  final v = TableRules(tableId: t.spec.id, crypto: crypto);
  for (final e in log) {
    v.feed(e);
    if (v.over && v.endN != null && v.log.length >= v.endN!) break;
  }
  if (first != null && (v.endHash != first.endHash || v.state != first.state)) {
    return 'the log read alone ends elsewhere: ${v.describe()} against ${first.describe()}';
  }
  switch (v.state) {
    case TableState.finished:
      if (v.game.phase != Phase.gameOver) return 'finished short of the target: ${v.describe()}';
    case TableState.ended:
      if (v.anyoneHere) return 'ended with somebody seated: ${v.describe()}';
    case TableState.failed:
      return 'the game failed, with the house never gone for good: ${v.describe()}';
    case TableState.waiting || TableState.playing:
      // Nobody left to ask the referee the time, and no house: the
      // table stays where it was, and nobody is waiting on it.
      if (sealed || following.isNotEmpty) return 'not over: ${v.describe()}';
  }
  count?.call('ended ${v.state.name}');
  // Nobody lost their seat but by a fault of their own.
  for (final MapEntry(key: seat, value: removal) in v.removals.entries) {
    count?.call('exit ${removal.exit.name}');
    final i = t.signers.indexWhere((s) => s.publicKey == (t.spec.seats[seat] as HumanSeat).key);
    if (removal.exit == Exit.left && !mayLeave.contains(i)) return 'p$i left without leaving';
    if (removal.exit == Exit.lied && !liars.contains(i)) return 'p$i found to lie, and did not';
    // A socket dropped for a few seconds, or a reload well inside the
    // silence, is no reason to lose a seat.
    if (!mayLose.contains(i)) return 'p$i lost their seat (${removal.exit.name}) with nothing wrong';
  }
  // Nothing said twice: a device says each turn's move once, and once
  // more only for a move the log has not had.
  final ids = <String>{};
  for (final e in log) {
    final id = e.event?.id ?? e.unread?['id'] as String?;
    if (id != null && !ids.add(id)) return 'the referee took ${e.event ?? id} twice, at #${e.n}';
  }
  final said = <String, Set<String>>{};
  for (final e in log) {
    final ev = e.event;
    if (ev == null || !{EventKind.deal, EventKind.pass, EventKind.play}.contains(ev.kind)) continue;
    final forTurn = said.putIfAbsent('${ev.author.substring(0, 6)} ${ev.turn}', () => {})..add(ev.id);
    if (forTurn.length > 1) return '${ev.author.substring(0, 6)} said ${ev.turn} twice';
  }
  // A sealed game the house saw through has its word on it in the log.
  if (sealed) {
    final said = [
      for (final e in log)
        if (e.event?.kind == EventKind.result && e.event!.author == t.houseSigner.publicKey) e.event!,
    ];
    if (said.isEmpty) return 'the house said nothing of how it came out';
    final word = said.first.body;
    if (word['n'] != v.endN || word['hash'] != v.endHash || word['state'] != v.state.name) {
      return 'the house said another end: $word against ${v.describe()}';
    }
    if (first != null && first.result == null) return 'the house\'s word not taken: $word';
    // And the result it published for the ratings is the one the log
    // comes to, said once.
    final made = GameResult.ofTable(v);
    if (t.results.length != (made == null ? 0 : 1)) return 'the house published ${t.results.length} results';
    if (made != null && jsonEncode(GameResult.parse(t.results.single)?.toJson()) != jsonEncode(made.toJson())) {
      return 'the house published another result: ${t.results.single.content}';
    }
  }
  return null;
}
