/// The app's transport: a WebRTC data channel to every other human at
/// the table, set up through the relay, and the relay itself beside
/// them — the path to a peer whose channel is not open, and the only
/// path to a juror, which follows the table from the relay alone.
///
/// Every message goes over every open channel and, once, through the
/// relay envelope; the table's own dedup by event id absorbs what
/// arrives twice. Sending to the relay only while a channel was down
/// left a juror deaf at a table whose four channels were all up — and
/// at a table of one person, who has no channels at all. What arrives
/// on a channel is from the peer at its far end; what arrives from the
/// relay is from the envelope's signer. A channel closing or failing is
/// reported as a disconnect, which the protocol treats as most of the
/// silence allowance already spent.
///
/// Who offers: of any two peers, the one with the lower key. ICE runs
/// without servers here — peers on one network, or a dev machine — and
/// a TURN server is a configuration away (docs/06-service.md).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:table/table.dart';

class MeshTransport implements Transport {
  MeshTransport({
    required this.relay,
    required this.peers,
    this.iceServers = const [],
    this.log,
  }) {
    _sub = relay.signals.listen(_onSignal);
    _relaySub = relay.incoming.listen(_incoming.add);
    for (final p in peers) {
      if (p != relay.signer.publicKey && p.compareTo(relay.signer.publicKey) > 0) _offerTo(p);
    }
  }

  final RelayTransport relay;

  /// Every human at the table, this peer included.
  final List<PublicKey> peers;
  final List<Map<String, Object?>> iceServers;
  final void Function(String line)? log;

  final Map<PublicKey, _Link> _links = {};
  final _incoming = StreamController<({PublicKey from, Map<String, Object?> message})>.broadcast();
  final _disconnected = StreamController<PublicKey>.broadcast();
  StreamSubscription<Signal>? _sub;
  StreamSubscription<void>? _relaySub;
  bool _closed = false;

  @override
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming => _incoming.stream;

  @override
  Stream<PublicKey> get disconnected => _disconnected.stream;

  /// Peers with an open data channel right now.
  Iterable<PublicKey> get connected => _links.entries.where((e) => e.value.open).map((e) => e.key);

  @override
  void broadcast(Map<String, Object?> message, {bool everywhere = false}) {
    final wire = jsonEncode(message);
    for (final p in peers) {
      if (p == relay.signer.publicKey) continue;
      final link = _links[p];
      if (link != null && link.open) link.channel!.send(RTCDataChannelMessage(wire));
    }
    // One envelope reaches everyone on the relay path: a peer whose
    // channel is down, and every juror following.
    relay.broadcast(message, everywhere: everywhere);
  }

  @override
  List<String> get paths => relay.paths;

  @override
  void heard(PublicKey peer, List<String> paths) => relay.heard(peer, paths);

  Future<RTCPeerConnection> _connection(PublicKey peer) async {
    final pc = await createPeerConnection({'iceServers': iceServers});
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      relay.signal(peer, Signal(from: '', type: 'ice', payload: {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }));
    };
    pc.onConnectionState = (s) {
      log?.call('${peer.substring(0, 6)}: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _dropped(peer);
      }
    };
    pc.onDataChannel = (ch) => _attach(peer, ch);
    return pc;
  }

  Future<void> _offerTo(PublicKey peer) async {
    if (_closed) return;
    final link = _links[peer] = _Link();
    final pc = await _connection(peer);
    link.pc = pc;
    final ch = await pc.createDataChannel('table', RTCDataChannelInit()..ordered = true);
    _attach(peer, ch);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    relay.signal(peer, Signal(from: '', type: 'offer', payload: {'sdp': offer.sdp}));
  }

  Future<void> _onSignal(Signal s) async {
    if (_closed || !peers.contains(s.from)) return;
    try {
      switch (s.type) {
        case 'offer':
          // The lower key offers; an offer from a higher key is a peer
          // that came back and started over, and is answered the same.
          final link = _links[s.from] = _Link();
          final pc = await _connection(s.from);
          link.pc = pc;
          await pc.setRemoteDescription(RTCSessionDescription(s.payload['sdp'] as String, 'offer'));
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          relay.signal(s.from, Signal(from: '', type: 'answer', payload: {'sdp': answer.sdp}));
          for (final c in link.pending) {
            await pc.addCandidate(c);
          }
          link.pending.clear();
        case 'answer':
          final pc = _links[s.from]?.pc;
          if (pc == null) return;
          await pc.setRemoteDescription(RTCSessionDescription(s.payload['sdp'] as String, 'answer'));
        case 'ice':
          final c = RTCIceCandidate(
            s.payload['candidate'] as String?,
            s.payload['sdpMid'] as String?,
            s.payload['sdpMLineIndex'] as int?,
          );
          final link = _links[s.from];
          if (link?.pc == null) {
            (link ?? (_links[s.from] = _Link())).pending.add(c);
          } else {
            await link!.pc!.addCandidate(c);
          }
      }
    } catch (e) {
      log?.call('signal ${s.type} from ${s.from.substring(0, 6)}: $e');
    }
  }

  void _attach(PublicKey peer, RTCDataChannel ch) {
    final link = _links[peer] ?? (_links[peer] = _Link());
    link.channel = ch;
    ch.onMessage = (m) {
      if (!m.isBinary) {
        try {
          _incoming.add((from: peer, message: Map<String, Object?>.from(jsonDecode(m.text) as Map)));
        } catch (_) {}
      }
    };
    ch.onDataChannelState = (s) {
      link.open = s == RTCDataChannelState.RTCDataChannelOpen;
      log?.call('${peer.substring(0, 6)} channel $s');
      if (s == RTCDataChannelState.RTCDataChannelClosed) _dropped(peer);
    };
    if (ch.state == RTCDataChannelState.RTCDataChannelOpen) link.open = true;
  }

  void _dropped(PublicKey peer) {
    final link = _links[peer];
    if (link == null || !link.open && link.pc == null) return;
    link.open = false;
    link.pc?.close();
    link.pc = null;
    link.channel = null;
    if (!_closed) _disconnected.add(peer);
    // The lower key tries again after a moment; the relay carries the
    // table meanwhile.
    if (!_closed && peer.compareTo(relay.signer.publicKey) > 0) {
      Future<void>.delayed(const Duration(seconds: 3), () => _offerTo(peer));
    }
  }

  @override
  void close() {
    _closed = true;
    _sub?.cancel();
    _relaySub?.cancel();
    for (final l in _links.values) {
      l.channel?.close();
      l.pc?.close();
    }
    _links.clear();
    _incoming.close();
    _disconnected.close();
    relay.close();
  }
}

class _Link {
  RTCPeerConnection? pc;
  RTCDataChannel? channel;
  bool open = false;
  final List<RTCIceCandidate> pending = [];
}
