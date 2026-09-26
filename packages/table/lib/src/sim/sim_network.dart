/// A network of peers with latency, loss, crashes and partitions, all
/// on the virtual clock. Optionally with relays: events travel over a
/// named relay rather than a single bus, each peer reaches some subset
/// of them, and a relay can go out for a while — the layer where a
/// table that could not hear itself was born, so the one the chaos
/// walk needs to be able to break.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../relay_policy.dart';
import '../signing.dart';
import '../transport.dart';
import 'virtual_clock.dart';

class SimNetwork {
  SimNetwork(this.clock, {int seed = 0, this.minLatencyMs = 20, this.maxLatencyMs = 80, this.detectDisconnectMs = 3000})
      : _random = Random(seed);

  final VirtualClock clock;
  int minLatencyMs;
  int maxLatencyMs;

  /// Fraction of messages lost on a healthy link, 0 to 1.
  double lossRate = 0;

  /// What has crossed the simulated wire: bytes said, and bytes
  /// handed over — one copy per peer that gets one. The clock here is
  /// virtual and the network deterministic, so the same seed gives the
  /// same counts to the byte, which is what makes a protocol change
  /// measurable at all (tool/wire_in_sim.dart). A real socket's totals
  /// swing a quarter either way between runs.
  int said = 0;
  int handed = 0;

  /// The same, by what was said and whether the sayer is the one who
  /// made it: a table says again what has not settled, and carries
  /// forward what a peer behind has missed. [byKind] counts what was
  /// handed over — bytes times listeners — and [saidByKind] what was
  /// said once, which is the one to compare against what a hand is
  /// actually made of.
  final Map<String, int> byKind = {};
  final Map<String, int> saidByKind = {};

  void _tally(PublicKey from, Map<String, Object?> message, String wire, int copies) {
    said += wire.length;
    handed += wire.length * copies;
    final kind = message['kind'];
    if (kind is! String) return;
    final own = message['author'] == from ? 'own' : 'carried';
    final key = '$kind $own';
    byKind[key] = (byKind[key] ?? 0) + wire.length * copies;
    saidByKind[key] = (saidByKind[key] ?? 0) + wire.length;
  }

  /// How long the transport takes to notice a peer is gone.
  final int detectDisconnectMs;

  /// The relays events travel over, in the order a writer prefers them.
  /// Empty is the classic single bus: every peer reaches everything,
  /// events go to all reachable peers, and the relay-aware paths below
  /// are inert — so a table set up without relays behaves exactly as
  /// it did before there were any.
  List<String> relays = const [];

  /// How long a writer keeps a relay out of its own running after a
  /// write to it was refused: the protocol's minute (relays.dart).
  int refusalMs = 60000;

  final Random _random;
  final Map<PublicKey, SimTransport> _peers = {};
  final Set<PublicKey> _dead = {};
  final Set<PublicKey> _offline = {};
  List<Set<PublicKey>> _partition = const [];

  /// Which relays each peer reaches — reads from and writes to. Unset
  /// means all of [relays]; a peer that has lost a relay reaches fewer,
  /// which is the half-deaf fault: it writes and reads where it still
  /// can, and a table event of its own can miss a peer that does not
  /// share a relay with it.
  final Map<PublicKey, Set<String>> _reaches = {};

  /// Relays out until a virtual time: a write to one is refused (the
  /// writer learns and backs off, as against a rate-limiting relay)
  /// and it delivers nothing while out.
  final Map<String, int> _relayOutUntil = {};

  int delivered = 0;
  int dropped = 0;

  SimTransport attach(PublicKey key) {
    final t = SimTransport._(this, key);
    _peers[key] = t;
    return t;
  }

  /// The relays [key] reaches: all of them until it has lost some.
  Set<String> reachOf(PublicKey key) => relays.isEmpty ? const {} : (_reaches[key] ?? relays.toSet());

  /// Sets which relays [key] reaches — the half-deaf fault and its end.
  void setReach(PublicKey key, Set<String> r) => _reaches[key] = r;

  /// A relay goes out until [untilMs]; a write to it is refused and it
  /// delivers nothing in the meantime.
  void relayOut(String relay, int untilMs) => _relayOutUntil[relay] = untilMs;

  bool _relayLive(String relay, int now) => (_relayOutUntil[relay] ?? 0) <= now;

  /// Ends every relay fault: relays back up, every peer reaching all.
  void healRelays() {
    _relayOutUntil.clear();
    _reaches.clear();
  }

  /// The peer's process dies: nothing more is sent or received, and the
  /// others' transports notice after [detectDisconnectMs].
  void crash(PublicKey key) {
    _dead.add(key);
    for (final other in _peers.values) {
      if (other.key == key) continue;
      clock.schedule(detectDisconnectMs, () => other._disconnected.add(key));
    }
  }

  /// The peer's link goes silent both ways without the transport
  /// noticing — a tunnel, a backgrounded tab.
  void goOffline(PublicKey key) => _offline.add(key);
  void comeOnline(PublicKey key) => _offline.remove(key);

  /// A peer that is heard and does nothing: its heartbeats go out,
  /// and everything it would otherwise say is dropped where it is
  /// said. Not a network fault — it is what a device looks like from
  /// the outside when its clock runs and its work does not, which a
  /// tab starved of a processor or a phone put in a pocket both do.
  /// Going offline models the other kind, where the silence itself is
  /// the sign.
  void doze(PublicKey key) => _dozing.add(key);
  void wake(PublicKey key) => _dozing.remove(key);
  final Set<PublicKey> _dozing = {};

  /// One message eaten where it is said, chosen by the caller. What
  /// [lossRate] gives as a rate over everything, this gives exactly:
  /// the single copy of one event that never arrives, which is the
  /// ordinary way a turn fails to settle and the case a test wants to
  /// name rather than fish for. Return true to swallow.
  bool Function(PublicKey from, Map<String, Object?> message)? swallow;

  /// One copy of one message steered, chosen per copy as it leaves:
  /// null sends it as the network would, a number of milliseconds
  /// holds it back that much longer, and a negative number loses it.
  /// Where [swallow] eats a message at its source, this reaches a
  /// single recipient — the shape of a reordering, one peer hearing
  /// two things the other way round from everybody else — which is
  /// what `tool/explore.dart` walks through one copy at a time.
  ///
  /// The copy's latency is drawn before it is asked, so a steered run
  /// draws the same numbers as an unsteered one and differs from it by
  /// the one copy and whatever that copy changes.
  int? Function(PublicKey from, PublicKey to, Map<String, Object?> message)? steer;

  bool _says(PublicKey from, Map<String, Object?> message) {
    if (swallow?.call(from, message) ?? false) {
      dropped++;
      return false;
    }
    return !_dozing.contains(from) || message['kind'] == 'heartbeat' || message['kind'] == 'serve';
  }

  /// Only peers on the same side can reach each other.
  void partition(List<Set<PublicKey>> sides) => _partition = sides;

  /// One link dead both ways, without either end noticing — a WebRTC
  /// channel that never opened, a relay subscription gone quiet — while
  /// every other link works.
  void cut(PublicKey a, PublicKey b) => _cuts.add({a, b});

  /// And that one link back, leaving every other fault standing —
  /// [heal] clears the lot, which is no use for a cut that is meant
  /// to outlast nothing but a moment.
  void uncut(PublicKey a, PublicKey b) => _cuts.removeWhere((c) => c.length == 2 && c.contains(a) && c.contains(b));
  final List<Set<PublicKey>> _cuts = [];

  void heal() {
    _partition = const [];
    _cuts.clear();
  }

  /// Whether [key]'s process is running and its link is not silent.
  bool isUp(PublicKey key) => !_dead.contains(key) && !_offline.contains(key);

  bool _reachable(PublicKey from, PublicKey to) {
    if (_dead.contains(from) || _dead.contains(to)) return false;
    if (_offline.contains(from) || _offline.contains(to)) return false;
    if (_cuts.any((c) => c.contains(from) && c.contains(to))) return false;
    for (final side in _partition) {
      if (side.contains(from) != side.contains(to)) return false;
    }
    return true;
  }

  int _latency() => minLatencyMs + _random.nextInt(maxLatencyMs - minLatencyMs + 1);

  /// The classic bus: to every reachable peer, no relay in the way.
  void _broadcastAll(PublicKey from, Map<String, Object?> message) {
    if (!_says(from, message)) return;
    final wire = jsonEncode(message);
    var copies = 0;
    for (final to in _peers.keys) {
      if (to == from) continue;
      if (!_reachable(from, to)) {
        dropped++;
        continue;
      }
      if (lossRate > 0 && _random.nextDouble() < lossRate) {
        dropped++;
        continue;
      }
      final latency = _latency();
      final held = steer?.call(from, to, message);
      if (held != null && held < 0) {
        dropped++;
        continue;
      }
      copies++;
      clock.schedule(latency + (held ?? 0), () {
        if (!_reachable(from, to)) {
          dropped++;
          return;
        }
        delivered++;
        _peers[to]!._incoming.add((from: from, message: jsonDecode(wire) as Map<String, Object?>));
      });
    }
    _tally(from, message, wire, copies);
  }

  /// The relay bus: written to [targets], and reaching a peer only if
  /// that peer reaches one of them and the link is otherwise up. A
  /// target relay that is out delivers nothing and, after a moment,
  /// tells the writer so — as a refused write does — so its next event
  /// goes elsewhere.
  void _deliverVia(PublicKey from, Map<String, Object?> message, Set<String> targets) {
    if (!_says(from, message)) return;
    final now = clock.nowMs;
    for (final r in targets) {
      if (!_relayLive(r, now)) {
        clock.schedule(_latency(), () => _peers[from]?._refused(r));
      }
    }
    final live = {for (final r in targets) if (_relayLive(r, now)) r};
    if (live.isEmpty) {
      dropped++;
      return;
    }
    final wire = jsonEncode(message);
    var copies = 0;
    for (final to in _peers.keys) {
      if (to == from) continue;
      if (!reachOf(to).any(live.contains)) {
        dropped++;
        continue;
      }
      if (!_reachable(from, to)) {
        dropped++;
        continue;
      }
      if (lossRate > 0 && _random.nextDouble() < lossRate) {
        dropped++;
        continue;
      }
      final latency = _latency();
      final held = steer?.call(from, to, message);
      if (held != null && held < 0) {
        dropped++;
        continue;
      }
      copies++;
      clock.schedule(latency + (held ?? 0), () {
        if (!_reachable(from, to)) {
          dropped++;
          return;
        }
        delivered++;
        _peers[to]!._incoming.add((from: from, message: jsonDecode(wire) as Map<String, Object?>));
      });
    }
    _tally(from, message, wire, copies);
  }
}

class SimTransport implements Transport {
  SimTransport._(this._net, this.key);

  final SimNetwork _net;
  final PublicKey key;
  final _incoming = StreamController<({PublicKey from, Map<String, Object?> message})>(sync: true);
  final _disconnected = StreamController<PublicKey>(sync: true);

  /// What each peer last said it reaches, and when — the same reckoning
  /// the real relay transport keeps, so a writer can pick a relay its
  /// readers can read.
  final Map<PublicKey, ({Set<String> reads, int at})> _peerReads = {};

  /// Relays this peer has had a write refused by lately, out of its own
  /// running until then.
  final Map<String, int> _refusedUntil = {};

  @override
  void broadcast(Map<String, Object?> message, {bool everywhere = false}) {
    if (_net.relays.isEmpty) return _net._broadcastAll(key, message);
    final now = _net.clock.nowMs;
    final reach = _net.reachOf(key);
    final up = {
      for (final r in _net.relays)
        if (reach.contains(r) && (_refusedUntil[r] ?? 0) <= now) r
    };
    final readBy = readByFrom(_peerReads, now, 120000);
    final Set<String> targets;
    if (floodWrite(up, readBy, everywhere: everywhere)) {
      targets = up;
    } else {
      final one = firstTarget(_net.relays, up, readBy);
      targets = one == null ? const {} : {one};
    }
    if (targets.isEmpty) return;
    _net._deliverVia(key, message, targets);
  }

  void _refused(String relay) => _refusedUntil[relay] = _net.clock.nowMs + _net.refusalMs;

  @override
  List<String> get paths => [for (final r in _net.relays) if (_net.reachOf(key).contains(r)) r];

  @override
  void heard(PublicKey peer, List<String> paths) {
    if (_net.relays.isEmpty) return;
    final reads = paths.toSet();
    if (reads.isEmpty) return;
    _peerReads[peer] = (reads: reads, at: _net.clock.nowMs);
  }

  @override
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming => _incoming.stream;

  @override
  Stream<PublicKey> get disconnected => _disconnected.stream;

  @override
  void reach(Set<PublicKey> peers) {
    // The simulated bus reaches every peer on it.
  }

  @override
  void close() {
    _incoming.close();
    _disconnected.close();
  }
}
