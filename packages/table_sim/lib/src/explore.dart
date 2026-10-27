/// Every one-event change to a short sealed game, one run each
/// (tool/explore.dart).
///
/// The chaos walk throws faults at a table at random and finds what
/// random faults find. What it rarely finds is the one event that
/// mattered going astray at exactly the wrong moment. This plays a
/// one-hand sealed game once to list every event the sides give their
/// lines to send, then again once per event and change, each run the
/// first with exactly that one thing different:
///
/// - **drop**: the sender's socket drops a moment after it sends, so the
///   event is lost on the way and has to be said again on the next one.
/// - **late**: the sender is off the network a moment after it sends,
///   for a few seconds: the event and everything after it is late.
/// - **twice**: the event is sent twice, as a device not sure it got
///   through sends it: the referee takes it once.
///
/// Each run is held to everything the chaos walk holds a table to
/// ([tableProblems]).
library;

import 'package:deal/deal.dart';
import 'package:table/table.dart';

import 'chaos_walk.dart';
import 'scripted_human.dart';
import 'sim_referee.dart';
import 'sim_table.dart';

enum Change { drop, late, twice }

/// A short game to explore, and what it does to itself on the way.
class Scenario {
  const Scenario(this.name, this.about, {this.humans = 2, this.setUp, this.mayLose = const {}, this.mayLeave = const {}});

  final String name;
  final String about;
  final int humans;

  /// What the scenario does to its table before it starts.
  final void Function(SimTable t)? setUp;

  /// The people who may lose their seats in it, and who leave.
  final Set<int> mayLose;
  final Set<int> mayLeave;

  static final all = [
    const Scenario('deal', 'two people and two bots play a hand'),
    const Scenario('four', 'four people play a hand', humans: 4),
    Scenario('leave', 'a person leaves mid-trick, and the other plays it out',
        setUp: (t) => t.people[0]
          ..going = Going.leave
          ..goAt = Moment(Moment.midTrick.name, Moment.midTrick.holds, fromHand: 0),
        mayLose: const {0},
        mayLeave: const {0}),
    Scenario('pass', 'a person leaves during the pass, and their hand is opened from the escrow',
        setUp: (t) => t.people[0]
          ..going = Going.leave
          ..goAt = Moment(Moment.duringPass.name, Moment.duringPass.holds, fromHand: 0),
        mayLose: const {0},
        mayLeave: const {0}),
    Scenario('reload', 'a person reloads as the pass opens',
        setUp: (t) => _onPass(t, () => t.reload(0, awayMs: 2000))),
    Scenario('house', 'the house restarts in the middle of the deal',
        setUp: (t) => t.clock.schedule(300, () => t.restartHouse(afterMs: 2000))),
  ];

  static Scenario? named(String name) {
    for (final s in all) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// Does [then] once, when person 0's pass first opens.
void _onPass(SimTable t, void Function() then) {
  var done = false;
  void look() {
    final c = t.clients[0];
    if (done || !c.started || !c.awaitingMyPass) return;
    done = true;
    then();
  }

  t.clients[0].changes.listen((_) => look());
}

SimTable _table(Scenario s, DealCrypto crypto, {bool traces = false}) {
  final t = SimTable(humans: s.humans, seed: 1, crypto: crypto, target: 1, traces: traces);
  s.setUp?.call(t);
  return t;
}

String _describe(SimLine line, TableEvent e) {
  final turn = e.body.containsKey('turn') ? ' ${e.turn}' : '';
  return '${line.key.substring(0, 6)} ${e.kind.name}$turn';
}

/// The events [s] gives its lines to send, in order, when nothing is
/// changed.
List<String> sendsOf(Scenario s, DealCrypto crypto) {
  final t = _table(s, crypto);
  final sent = <String>[];
  t.referee.onSend = (line, e) => sent.add(_describe(line, e));
  t.start();
  try {
    t.run(limitMs: 60 * 60 * 1000);
  } finally {
    t.close();
  }
  return sent;
}

/// One run of [s] with [change] made to the [k]th event given to a line:
/// null when every invariant held, what broke when one did not.
/// [holdMs] is how long a late sender is off the network.
String? exploreOne(Scenario s, DealCrypto crypto, int k, Change change, {int holdMs = 3000, bool traces = false}) {
  final t = _table(s, crypto, traces: traces);
  var n = 0;
  String? changed;
  t.referee.onSend = (line, e) {
    if (n++ != k) return;
    changed = _describe(line, e);
    // A moment after, as a socket's own events come: not from inside the
    // send.
    switch (change) {
      case Change.drop:
        t.clock.schedule(0, line.drop);
      case Change.late:
        t.clock.schedule(0, () {
          line.hold();
          t.clock.schedule(holdMs, line.release);
        });
      case Change.twice:
        t.clock.schedule(0, () => line.sendAgain(e));
    }
  };
  t.start();
  try {
    if (!t.run(limitMs: 60 * 60 * 1000)) {
      return '${change.name} $changed: the game did not end: ${[for (final c in t.following) c.rules.describe()].join(' / ')}';
    }
    final problem = tableProblems(t, mayLose: s.mayLose, mayLeave: s.mayLeave);
    if (problem != null) return '${change.name} $changed: $problem';
    if (changed == null) return 'there is no event $k';
    return null;
  } catch (e, st) {
    return '${change.name} $changed: threw: $e\n${st.toString().split('\n').take(8).join('\n')}';
  } finally {
    t.close();
  }
}
