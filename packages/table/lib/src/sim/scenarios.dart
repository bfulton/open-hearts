/// Scenarios the tests and the trace tool share, so any failing cell can
/// be replayed with a transition log.
library;

import 'dart:math';

import 'package:deal/deal.dart';

import '../signing.dart';
import 'scripted_human.dart';
import 'sim_juror.dart';
import 'sim_table.dart';

/// One departure in a matrix cell: [seat] goes by [how] at [when].
class Departure {
  const Departure(this.seat, this.how, this.when);
  final int seat;
  final Exit how;
  final Moment when;
}

/// A cell of the departure matrix: a table, some departures, and an
/// optional partition for a while after the first hand.
class MatrixCell {
  MatrixCell({
    required this.humans,
    this.departures = const [],
    this.seed = 1,
    this.partitionFirst = 0,
    this.partitionMs = 0,
  });

  final int humans;
  final List<Departure> departures;
  final int seed;

  /// Splits the first this-many humans from the rest, once the first
  /// hand is over, for [partitionMs].
  final int partitionFirst;
  final int partitionMs;

  late final SimTable table = SimTable(humans: humans, seed: seed);

  /// Runs the cell to its end. [beforeHeal] sees the table mid-partition.
  void run({void Function(SimTable)? beforeHeal}) {
    final t = table;
    for (final d in departures) {
      t.people[d.seat]
        ..exit = d.how
        ..exitAt = d.when;
    }
    t.start();
    if (partitionFirst > 0) {
      t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 3600000);
      final keys = t.signers.map((s) => s.publicKey).toList();
      t.net.partition([keys.sublist(0, partitionFirst).toSet(), keys.sublist(partitionFirst).toSet()]);
      t.clock.advance(partitionMs);
      beforeHeal?.call(t);
      t.net.heal();
    }
    t.run();
  }
}

/// A random walk: departures, partitions, blips, loss and latency at
/// random times over the first few minutes, then quiet.
class ChaosScenario {
  ChaosScenario(this.seed, {this.jurors = 4, DealCrypto? crypto, bool sweepJurors = false, bool workers = false, this.twins = false})
      : rng = Random(seed) {
    humans = 2 + rng.nextInt(3);
    table = SimTable(
        humans: humans, seed: 100 + seed, netSeed: seed, jurors: jurors, crypto: crypto, sweepJurors: sweepJurors, workers: workers);
    // Three relays under the table, everyone reaching all of them to
    // start: the same as a single bus until a fault takes a relay out
    // or leaves a peer reaching fewer, which is where a table learns
    // whether it can still hear itself. A shorter refusal backoff than
    // the protocol's minute, so a relay that came back is used again
    // well inside the walk's quiet tail.
    table.net.relays = const ['ra', 'rb', 'rc'];
    table.net.refusalMs = 30000;
  }

  /// Strangers online to draw a jury from; zero for the players' own
  /// protocol alone.
  final int jurors;

  /// Accounts on two devices: as it walks, a juror's account or a
  /// seated player's is taken up on a new device, which supersedes the
  /// old one — the old one cut off by the relay where it stands
  /// (docs/06-service.md, "One device at a time"). A player's new
  /// device is online, drawable by any table but this one, and the
  /// seat it left is the table's to take as a departure.
  final bool twins;

  /// New devices made so far, for their names.
  int _twinsMade = 0;

  final int seed;
  final Random rng;
  late final int humans;
  late final SimTable table;
  final List<String> faults = [];

  /// Virtual time by which every fault has started and ended.
  late int quietAt;

  /// Schedules the faults. Call after [SimTable.start].
  void schedule() {
    final t = table;
    final keys = t.signers.map((s) => s.publicKey).toList();
    final maxExits = humans - 1;
    var exits = 0;
    var at = 5000 + rng.nextInt(20000);
    final count = 3 + rng.nextInt(6);
    for (var f = 0; f < count; f++) {
      final when = at;
      final base = jurors > 0 ? 8 : 6;
      final kind = rng.nextInt(base + (twins ? 6 : 4));
      if (kind >= base + 4) {
        _twin(when, player: kind == base + 5, exitsLeft: () => exits < maxExits, exited: () => exits++);
        at += 3000 + rng.nextInt(30000);
        continue;
      }
      if (kind == base + 2) {
        // One event eaten where it is said, and only one. Loss as a
        // rate finds the peer that is repeated at until something
        // gets through; a single copy that never arrives finds the
        // event nobody ever says again, which is a different fault
        // and the one that stops a hand dead (`SimNetwork.swallow`).
        const kinds = ['deal', 'play', 'pass', 'witness', 'jury', 'release'];
        final eat = kinds[rng.nextInt(kinds.length)];
        t.clock.schedule(when, () {
          var eaten = false;
          t.net.swallow = (from, message) {
            if (eaten || message['kind'] != eat) return false;
            eaten = true;
            faults.add('ate one $eat from ${from.substring(0, 4)} at ${t.clock.nowMs}');
            return true;
          };
        });
        at += 3000 + rng.nextInt(30000);
        continue;
      }
      if (kind == base + 3) {
        // A summons that takes its time. It is not a table event — it
        // goes to the juror's presence over a relay — so a juror can
        // be told it is one well after the seats have said the hand's
        // first steps, and then holds them before it has a deal to
        // put them in.
        final p = t.presence;
        if (p != null) {
          final slow = 1000 + rng.nextInt(9000);
          final hold = 10000 + rng.nextInt(40000);
          t.clock.schedule(when, () {
            p.summonsMs = slow;
            faults.add('summons takes $slow at ${t.clock.nowMs} for $hold');
          });
          t.clock.schedule(when + hold, () => p.summonsMs = 50);
        }
        at += 3000 + rng.nextInt(30000);
        continue;
      }
      if (kind >= base) {
        if (kind == base) {
          // A relay goes out for a while: a write to it is refused and
          // it carries nothing, so the events that were going there
          // must find another relay the readers share.
          final r = t.net.relays[rng.nextInt(t.net.relays.length)];
          final hold = 5000 + rng.nextInt(40000);
          t.clock.schedule(when, () {
            t.net.relayOut(r, t.clock.nowMs + hold);
            faults.add('relay $r out at ${t.clock.nowMs} for $hold');
          });
        } else {
          // A peer goes half-deaf: it loses a relay from its reach, so
          // its own events can miss a peer that shares no other relay
          // with it, and it can miss theirs. Players and jurors alike —
          // a juror that cannot hear a seat is how a live seat gets
          // taken for absent. Never its last relay, or it is simply cut.
          final all = [
            for (final k in keys) k,
            for (final j in t.jurors) j.signer.publicKey,
          ];
          final k = all[rng.nextInt(all.length)];
          final r = t.net.relays[rng.nextInt(t.net.relays.length)];
          final hold = 5000 + rng.nextInt(60000);
          t.clock.schedule(when, () {
            final cur = t.net.reachOf(k).toSet();
            if (cur.length <= 1) return;
            cur.remove(r);
            t.net.setReach(k, cur);
            faults.add('${k.substring(0, 4)} half-deaf to $r at ${t.clock.nowMs} for $hold');
          });
          t.clock.schedule(when + hold, () => t.net.setReach(k, t.net.reachOf(k).toSet()..add(r)));
        }
        at += 3000 + rng.nextInt(30000);
        continue;
      }
      switch (kind) {
        case 0:
        case 1:
          // Half of them out of earshot of a juror or two as they go.
          //
          // A departure turns a seat into a bot, and which seats are
          // bots is half of who holds them — so a departure still in
          // flight is two sides answering that differently, which is
          // the race `_botSeatsAt` is there for. Departures otherwise
          // reach everyone at once bar the ordinary latency, and a
          // relay going half-deaf lasts tens of seconds rather than the
          // second or two that puts one side a step behind another. So
          // the leaver loses a link to a juror or two for a moment, and
          // they hear it carried rather than said.
          final late = rng.nextBool();
          t.clock.schedule(when, () {
            if (exits >= maxExits) return;
            final live = t.people.where((p) => !p.gone).toList();
            if (live.length < 2) return;
            final who = live[rng.nextInt(live.length)];
            final how = Exit.values[rng.nextInt(Exit.values.length)];
            exits++;
            final deaf = late ? t.jurors.where((j) => !j.gone && j.client != null).take(2).toList() : const <SimJuror>[];
            for (final j in deaf) {
              t.net.cut(who.client.signer.publicKey, j.signer.publicKey);
            }
            faults.add('${how.name} seat ${who.client.mySeat} at ${t.clock.nowMs}'
                '${deaf.isEmpty ? '' : ', ${deaf.length} juror(s) out of earshot'}');
            who.depart(how);
            if (deaf.isNotEmpty) {
              t.clock.schedule(1500, () {
                for (final j in deaf) {
                  t.net.uncut(who.client.signer.publicKey, j.signer.publicKey);
                }
              });
            }
          });
        case 2:
          final side = <PublicKey>{};
          for (final k in keys) {
            if (rng.nextBool()) side.add(k);
          }
          final hold = 5000 + rng.nextInt(60000);
          t.clock.schedule(when, () {
            t.net.partition([side, keys.toSet().difference(side)]);
            faults.add('split ${side.length}/${keys.length - side.length} at ${t.clock.nowMs} for $hold');
          });
          t.clock.schedule(when + hold, t.net.heal);
        case 3:
          final k = keys[rng.nextInt(keys.length)];
          final hold = 2000 + rng.nextInt(45000);
          t.clock.schedule(when, () {
            t.net.goOffline(k);
            faults.add('blip ${k.substring(0, 4)} at ${t.clock.nowMs} for $hold');
          });
          t.clock.schedule(when + hold, () {
            // A blip ends unless the same peer has since gone quiet for good.
            if (!t.people.any((p) => p.client.signer.publicKey == k && p.gone && p.exit == Exit.idle)) {
              t.net.comeOnline(k);
            }
          });
        case 4:
          final rate = 0.1 + rng.nextDouble() * 0.5;
          final hold = 5000 + rng.nextInt(40000);
          t.clock.schedule(when, () {
            t.net.lossRate = rate;
            faults.add('loss ${rate.toStringAsFixed(2)} at ${t.clock.nowMs} for $hold');
          });
          t.clock.schedule(when + hold, () => t.net.lossRate = 0);
        case 5:
          final hold = 5000 + rng.nextInt(40000);
          t.clock.schedule(when, () {
            t.net.minLatencyMs = 200;
            t.net.maxLatencyMs = 2500;
            faults.add('latency at ${t.clock.nowMs} for $hold');
          });
          t.clock.schedule(when + hold, () {
            t.net.minLatencyMs = 20;
            t.net.maxLatencyMs = 80;
          });
        case 6:
        case 7:
          // A juror goes — one, or the foreman, or several at once, up
          // to the whole jury.
          final n = 1 + rng.nextInt(t.jurors.length);
          final how = Exit.values[rng.nextInt(Exit.values.length)];
          t.clock.schedule(when, () {
            final up = t.jurors.where((j) => !j.gone).toList();
            for (final j in up.take(n)) {
              j.depart(how);
              faults.add('juror ${j.signer.publicKey.substring(0, 4)} ${how.name}s at ${t.clock.nowMs}');
            }
          });
      }
      at += 3000 + rng.nextInt(30000);
    }
    quietAt = at + 70000;
  }

  /// At [when], an account taken up on a new device: a seated player's
  /// with [player], else a juror's. The new device is online at once;
  /// the old one is superseded, and the relay drops it — a crash, as
  /// far as anyone else can tell. A player's counts against the
  /// table's departures ([exitsLeft], [exited]), as any other way out
  /// of a seat does.
  void _twin(int when, {required bool player, required bool Function() exitsLeft, required void Function() exited}) {
    final t = table;
    final p = t.presence;
    if (p == null) return;
    t.clock.schedule(when, () {
      final String account;
      final void Function() supersede;
      final String was;
      if (player) {
        if (!exitsLeft()) return;
        final live = t.people.where((x) => !x.gone).toList();
        if (live.length < 2) return;
        final who = live[rng.nextInt(live.length)];
        account = p.accountOf(who.client.signer.publicKey);
        was = 'seat ${who.client.mySeat}';
        exited();
        supersede = () => who.depart(Exit.crash);
      } else {
        final up = t.jurors.where((j) => !j.gone && !p.lastResorts.contains(j)).toList();
        if (up.isEmpty) return;
        final old = up[rng.nextInt(up.length)];
        account = p.accountOf(old.signer.publicKey);
        was = 'juror ${old.signer.publicKey.substring(0, 4)}';
        supersede = () => old.depart(Exit.crash);
      }
      final signer = FakeSigner('twin${_twinsMade++}-$seed');
      final device = SimJuror(signer, t.net, t.clock, crypto: t.crypto, account: account)..sweeps = t.jurors.isNotEmpty && t.jurors.first.sweeps;
      t.jurors.add(device);
      p.register(device);
      supersede();
      faults.add('$was\'s account taken up on ${signer.publicKey.substring(0, 4)} at ${t.clock.nowMs}');
    });
  }

  /// Ends every fault that is not a departure for good.
  void quiet() {
    final t = table;
    t.net.heal();
    t.net.healRelays();
    t.net.swallow = null;
    t.presence?.summonsMs = 50;
    t.net.lossRate = 0;
    t.net.minLatencyMs = 20;
    t.net.maxLatencyMs = 80;
    for (final p in t.people) {
      if (!(p.gone && p.exit == Exit.idle)) t.net.comeOnline(p.client.signer.publicKey);
    }
  }
}
