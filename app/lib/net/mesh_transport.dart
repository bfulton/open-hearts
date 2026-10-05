/// The app's transport: a WebRTC data channel to everyone this device
/// has to reach at a table — the other humans seated, and the hand's
/// jurors — set up through the relay, with the relay itself behind
/// them as the lane for whoever has no channel open.
///
/// Who that is grows: the seats are known when the table starts, and
/// the jurors as each jury carries, so the client says again who to
/// reach and the mesh dials whatever is new ([reach]). It only ever
/// adds. A client's view of the table lags — a juror that has not yet
/// seen a seat sit down leaves it out — and dropping a channel on that
/// would report a disconnect for somebody who never went anywhere.
/// Channels end by failing or by the transport closing with the table.
///
/// Every message goes over every open channel as bytes — a table event
/// framed, not JSON, because nothing between two channel ends has to
/// read it (`frame.dart`, 36% off a hand and no compressor) — and
/// through the relay envelope as JSON while anyone to be reached is
/// without a channel, because a relay does have to read what it
/// carries. The table's own dedup by event id absorbs what arrives
/// twice, and an event's id is the same whichever way it came. The
/// relay is a fallback, not a primary path (docs/02-multiplayer.md):
/// with every channel up the lane says nothing at all, and a table at
/// full strength costs the relays its presence and its signalling.
///
/// What arrives on a channel is from the peer at its far end; what
/// arrives from the relay is from the envelope's signer. A channel
/// closing or failing is reported as a disconnect, which the protocol
/// treats as most of the silence allowance already spent.
///
/// Who offers: of any two peers, the one with the lower key.
///
/// A channel goes through a TURN server and nowhere else, so no peer —
/// a stranger drawn as a juror among them — ever learns another's
/// address. Without a TURN server to hand, no channel is made at all and
/// the relay carries the table.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:table/table.dart';
import 'remote_config.dart' show waits;

class MeshTransport implements Transport {
  MeshTransport({
    required this.relay,
    required Iterable<PublicKey> peers,
    this.iceServers = const [],
    this.log,
  }) : peers = peers.toSet() {
    _sub = relay.signals.listen(_onSignal);
    _relaySub = relay.incoming.listen(_incoming.add);
    for (final p in this.peers) {
      _dial(p);
    }
  }

  /// Of any two peers, the one with the lower key offers; the other
  /// waits to be offered to.
  void _dial(PublicKey peer) {
    if (!_channels || peer == relay.signer.publicKey || _links.containsKey(peer)) return;
    if (peer.compareTo(relay.signer.publicKey) > 0) _offerTo(peer);
  }

  /// Only ever adds, for the reason at the top of this file.
  @override
  void reach(Set<PublicKey> who) {
    if (_closed) return;
    for (final p in who) {
      if (peers.add(p)) {
        log?.call('reaching ${p.substring(0, 6)}');
        _dial(p);
      }
    }
  }

  final RelayTransport relay;

  /// Everyone this device dials: the seats at the start, and the
  /// hand's jurors as [reach] names them. The relay is signalling, and
  /// the lane for a peer whose channel is not up.
  final Set<PublicKey> peers;
  final List<Map<String, Object?>> iceServers;
  final void Function(String line)? log;

  bool get _channels => makesChannels(iceServers);

  /// Whether a device makes channels at all: only with a TURN server.
  static bool makesChannels(List<Map<String, Object?>> iceServers) => iceServers.any(isTurn);

  /// Whether [server] is a TURN server (not STUN).
  static bool isTurn(Map<String, Object?> server) {
    final urls = server['urls'];
    final list = urls is List ? urls : [urls];
    return list.any((u) => u is String && (u.startsWith('turn:') || u.startsWith('turns:')));
  }

  /// What a peer connection is made with: through TURN alone, so the
  /// browser gathers no address of its own to send.
  static Map<String, Object?> rtcConfiguration(List<Map<String, Object?>> iceServers) => {
        'iceServers': iceServers,
        'iceTransportPolicy': 'relay',
      };

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
    // Bytes down the channel, JSON to the relay: the relay is a
    // stranger's machine that has to read and store what it carries,
    // and the channel is not (`frame.dart`). Anything the framing
    // does not recognise goes down the channel as the JSON it is.
    final frame = encodeFrame(message, table: relay.table);
    final wire = frame == null
        ? RTCDataChannelMessage(jsonEncode(message))
        : RTCDataChannelMessage.fromBinary(frame);
    // A channel can be closing under the send: the browser has it
    // closing, and the state change that says so is still on its way
    // here. The browser's send throws then; uncaught, the throw would
    // skip the peers after it and the relay lane below, and stop
    // whatever made the send half done. So a channel
    // that refuses is passed over, and the relay carries the message
    // to that peer as it would with no channel up. Whether the
    // channel is up stays the state change's to say: a send can also
    // be refused for a queue that is full, on a channel that is fine.
    final refused = <PublicKey>{};
    for (final p in peers) {
      if (p == relay.signer.publicKey) continue;
      final link = _links[p];
      if (link == null || !link.open) continue;
      try {
        // Thrown here in a browser; a failed future on a phone.
        link.channel!.send(wire).catchError((Object e) {
          log?.call('${p.substring(0, 6)} channel refused a send: $e');
        });
      } catch (e) {
        refused.add(p);
        log?.call('${p.substring(0, 6)} channel refused a send ($e); the relay carries it');
      }
    }
    // And the relay lane for whoever has no channel up: a fallback
    // (docs/02-multiplayer.md), not a second primary path. With every
    // peer connected this says nothing at all, and a table at full
    // strength costs the relays a heartbeat and its signalling.
    if (refused.isNotEmpty || peers.any((p) => p != relay.signer.publicKey && !(_links[p]?.open ?? false))) {
      relay.broadcast(message, everywhere: everywhere);
    }
  }

  @override
  List<String> get paths => relay.paths;

  @override
  void heard(PublicKey peer, List<String> paths) => relay.heard(peer, paths);

  Future<RTCPeerConnection> _connection(PublicKey peer) async {
    final pc = await createPeerConnection(rtcConfiguration(iceServers));
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
    final tries = (_links[peer]?.tries ?? 0) + 1;
    final link = _links[peer] = _Link()..tries = tries;
    // An offer that is never answered is not free: it holds a peer
    // connection open, and its candidates are sealed and published one
    // by one. Some peers never answer — a juror of last resort runs in
    // the service's VM with no WebRTC in it at all — so a dial that has
    // not come up in time (remote config, waits.meshAnswer) is let go
    // of, and the relay lane carries that peer, which is what the lane
    // is for.
    link.giveUp = Timer(waits.meshAnswer, () => _unanswered(peer));
    final pc = await _connection(peer);
    if (_closed || _links[peer] != link) {
      await pc.close();
      return;
    }
    link.pc = pc;
    final ch = await pc.createDataChannel('table', RTCDataChannelInit()..ordered = true);
    _attach(peer, ch);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    relay.signal(peer, Signal(from: '', type: 'offer', payload: {'sdp': offer.sdp}));
  }

  /// A dial that never came up. The connection goes, the peer stays
  /// in [peers] so the relay lane keeps carrying it, and the next
  /// attempt waits longer than the last — a minute, then two, then
  /// four, to a quarter of an hour. Nothing is reported as a
  /// disconnect: a channel that never opened says nothing about
  /// whether anybody is there, and the protocol would read it as most
  /// of the silence allowance already spent.
  void _unanswered(PublicKey peer) {
    final link = _links[peer];
    if (link == null || link.open || _closed) return;
    log?.call('${peer.substring(0, 6)} did not answer; the relay carries them');
    link.giveUp = null;
    link.pc?.close();
    link.pc = null;
    link.channel = null;
    // Dialling again is the lower key's, as dialling is ([_dial]); a
    // side that only answered lets the connection go and waits to be
    // offered to.
    if (peer.compareTo(relay.signer.publicKey) < 0) return;
    final steps = (link.tries - 1).clamp(0, 4);
    Future<void>.delayed(Duration(minutes: 1 << steps), () {
      if (_closed || !peers.contains(peer)) return;
      if (_links[peer]?.open ?? false) return;
      _offerTo(peer);
    });
  }

  Future<void> _onSignal(Signal s) async {
    if (_closed || !peers.contains(s.from)) return;
    try {
      switch (s.type) {
        case 'offer':
          // Not answered where this device makes no channels: the
          // offerer gives up on it and the relay carries the two.
          if (!_channels) return;
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
      try {
        final message = m.isBinary ? decodeFrame(m.binary, table: relay.table) : Map<String, Object?>.from(jsonDecode(m.text) as Map);
        if (message != null) _incoming.add((from: peer, message: message));
      } catch (_) {
        // A message this build cannot read is one peer's problem, not
        // the table's: the protocol says everything again.
      }
    };
    ch.onDataChannelState = (s) {
      link.open = s == RTCDataChannelState.RTCDataChannelOpen;
      if (link.open) _answered(link);
      log?.call('${peer.substring(0, 6)} channel $s');
      if (s == RTCDataChannelState.RTCDataChannelClosed) _dropped(peer);
    };
    if (ch.state == RTCDataChannelState.RTCDataChannelOpen) {
      link.open = true;
      _answered(link);
    }
  }

  void _answered(_Link link) {
    link.everOpen = true;
    link.tries = 0;
    link.giveUp?.cancel();
    link.giveUp = null;
  }

  void _dropped(PublicKey peer) {
    final link = _links[peer];
    if (link == null || !link.open && link.pc == null) return;
    // A connection that failed on its way up is a dial that was never
    // answered, not a peer that went away: it goes through
    // [_unanswered], which says nothing and waits longer each time.
    if (!link.everOpen) {
      _unanswered(peer);
      return;
    }
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
      l.giveUp?.cancel();
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

  /// Whether this peer's channel has ever been up. A channel that has
  /// been open and closes is a disconnect; one that never opened is a
  /// dial nobody answered, which is a different thing.
  bool everOpen = false;

  /// Dials that went unanswered in a row, which is what the wait
  /// before the next one is made of.
  int tries = 0;
  Timer? giveUp;
  final List<RTCIceCandidate> pending = [];
}
