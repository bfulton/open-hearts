/// A network of peers with latency, loss, crashes and partitions, all
/// on the virtual clock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

  /// How long the transport takes to notice a peer is gone.
  final int detectDisconnectMs;

  final Random _random;
  final Map<PublicKey, SimTransport> _peers = {};
  final Set<PublicKey> _dead = {};
  final Set<PublicKey> _offline = {};
  List<Set<PublicKey>> _partition = const [];

  int delivered = 0;
  int dropped = 0;

  SimTransport attach(PublicKey key) {
    final t = SimTransport._(this, key);
    _peers[key] = t;
    return t;
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

  /// Only peers on the same side can reach each other.
  void partition(List<Set<PublicKey>> sides) => _partition = sides;

  /// One link dead both ways, without either end noticing — a WebRTC
  /// channel that never opened, a relay subscription gone quiet — while
  /// every other link works.
  void cut(PublicKey a, PublicKey b) => _cuts.add({a, b});
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

  void _broadcast(PublicKey from, Map<String, Object?> message) {
    final wire = jsonEncode(message);
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
      final latency = minLatencyMs + _random.nextInt(maxLatencyMs - minLatencyMs + 1);
      clock.schedule(latency, () {
        if (!_reachable(from, to)) {
          dropped++;
          return;
        }
        delivered++;
        _peers[to]!._incoming.add((from: from, message: jsonDecode(wire) as Map<String, Object?>));
      });
    }
  }
}

class SimTransport implements Transport {
  SimTransport._(this._net, this.key);

  final SimNetwork _net;
  final PublicKey key;
  final _incoming = StreamController<({PublicKey from, Map<String, Object?> message})>(sync: true);
  final _disconnected = StreamController<PublicKey>(sync: true);

  @override
  void broadcast(Map<String, Object?> message) => _net._broadcast(key, message);

  @override
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming => _incoming.stream;

  @override
  Stream<PublicKey> get disconnected => _disconnected.stream;

  @override
  void close() {
    _incoming.close();
    _disconnected.close();
  }
}
