/// A [Transport] over a Nostr relay, and the signalling that WebRTC
/// needs on the same wire.
///
/// Every message the table broadcasts goes to the relay as an ephemeral
/// event of kind [TableKinds.table], tagged with the table id and
/// signed by this peer, with the message as its content. Everyone at
/// the table subscribes to that kind and tag. What arrives is stamped
/// `from` the event's signer — the peer that sent it, which for a
/// relayed message is not its author — and that is the distinction the
/// protocol's "heard from" depends on.
///
/// A relay is a meeting point, not a friend: it says nothing when a peer
/// goes, so [disconnected] never fires here. The protocol's heartbeats
/// carry that. When the socket itself drops, the transport reconnects
/// with a growing pause and subscribes again.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr.dart';
import 'signing.dart';
import 'transport.dart';

class RelayTransport implements Transport {
  RelayTransport({required this.url, required this.signer, required this.table, this.log}) {
    _connect();
  }

  final Uri url;
  final Signer signer;
  final String table;
  final void Function(String line)? log;

  final _incoming = StreamController<({PublicKey from, Map<String, Object?> message})>.broadcast();
  final _disconnected = StreamController<PublicKey>.broadcast();
  final _signals = StreamController<Signal>.broadcast();
  final _lobby = StreamController<NostrEvent>.broadcast();

  WebSocketChannel? _channel;
  bool _closed = false;
  int _retryMs = 500;
  final Set<String> _seen = {};

  /// Resolves once the relay has acknowledged the subscription.
  Future<void> get ready => _ready.future;
  Completer<void> _ready = Completer<void>();

  @override
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming => _incoming.stream;

  @override
  Stream<PublicKey> get disconnected => _disconnected.stream;

  /// Offers, answers and candidates addressed to this peer.
  Stream<Signal> get signals => _signals.stream;

  /// Lobby events for this table id — hosting, joining, starting — the
  /// relay's stored history first, then live. Anyone's, this peer's
  /// own included.
  Stream<NostrEvent> get lobby => _lobby.stream;

  /// Publishes a lobby event, tagged with the table id.
  void announce(Map<String, Object?> content) {
    _publish(NostrEvent.sign(signer, kind: TableKinds.lobby, content: jsonEncode(content), tags: [
      ['t', table],
    ]));
  }

  @override
  void broadcast(Map<String, Object?> message) {
    _publish(NostrEvent.sign(signer, kind: TableKinds.table, content: jsonEncode(message), tags: [
      ['t', table],
    ]));
  }

  /// Sends one signalling message to [to].
  void signal(PublicKey to, Signal s) {
    _publish(NostrEvent.sign(signer, kind: TableKinds.signal, content: jsonEncode(s.toJson()), tags: [
      ['p', to],
      ['t', table],
    ]));
  }

  void _publish(NostrEvent e) {
    final ch = _channel;
    if (ch == null) return; // between connections: the protocol repeats
    try {
      ch.sink.add(jsonEncode(['EVENT', e.toJson()]));
    } catch (_) {}
  }

  void _connect() {
    if (_closed) return;
    final ch = WebSocketChannel.connect(url);
    _channel = ch;
    ch.stream.listen(_onMessage, onDone: _onDropped, onError: (_) => _onDropped());
    ch.ready.then((_) {
      _retryMs = 500;
      ch.sink.add(jsonEncode([
        'REQ',
        'table',
        const Filter(kinds: [TableKinds.table]).toJson()..['#t'] = [table],
        Filter(kinds: const [TableKinds.signal], tags: {'p': [signer.publicKey]}).toJson()..['#t'] = [table],
        const Filter(kinds: [TableKinds.lobby]).toJson()..['#t'] = [table],
      ]));
      log?.call('connected to $url');
    }).catchError((Object e) {
      log?.call('connect failed: $e');
    });
  }

  void _onDropped() {
    if (_closed) return;
    _channel = null;
    if (!_ready.isCompleted) {
      // Nothing was ever acknowledged: keep the same future for the caller.
    } else {
      _ready = Completer<void>();
    }
    log?.call('dropped; retrying in $_retryMs ms');
    Future<void>.delayed(Duration(milliseconds: _retryMs), _connect);
    _retryMs = (_retryMs * 2).clamp(500, 10000);
  }

  void _onMessage(Object? raw) {
    List<Object?> m;
    try {
      m = jsonDecode(raw as String) as List<Object?>;
    } catch (_) {
      return;
    }
    if (m.isEmpty) return;
    switch (m[0]) {
      case 'EOSE':
        if (!_ready.isCompleted) _ready.complete();
      case 'EVENT':
        if (m.length != 3) return;
        final e = NostrEvent.parse(m[2]);
        if (e == null || e.tag('t') != table) return;
        if (!_seen.add(e.id)) return;
        if (_seen.length > 50000) _seen.clear();
        if (e.kind == TableKinds.lobby) {
          _lobby.add(e);
          return;
        }
        if (e.pubkey == signer.publicKey) return;
        if (e.kind == TableKinds.table) {
          try {
            final message = Map<String, Object?>.from(jsonDecode(e.content) as Map);
            _incoming.add((from: e.pubkey, message: message));
          } catch (_) {}
        } else if (e.kind == TableKinds.signal && e.tag('p') == signer.publicKey) {
          final s = Signal.parse(e.pubkey, e.content);
          if (s != null) _signals.add(s);
        }
      case 'OK':
        if (m.length >= 3 && m[2] == false) log?.call('relay refused ${m[1]}: ${m.length > 3 ? m[3] : ''}');
      case 'NOTICE':
        log?.call('relay: ${m.length > 1 ? m[1] : ''}');
    }
  }

  @override
  void close() {
    _closed = true;
    _channel?.sink.close();
    _channel = null;
    _incoming.close();
    _disconnected.close();
    _signals.close();
    _lobby.close();
  }
}

/// One WebRTC signalling message: an offer or answer carrying SDP, or
/// an ICE candidate. Plain text on the relay for now — a local relay
/// on a dev machine; encryption to the recipient's key (NIP-44) is the
/// step before a public relay carries it.
class Signal {
  const Signal({required this.from, required this.type, required this.payload});

  final PublicKey from;

  /// `offer`, `answer` or `ice`.
  final String type;

  /// For offer and answer, `{'sdp': …}`; for ice, the candidate's own
  /// JSON (`candidate`, `sdpMid`, `sdpMLineIndex`).
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {'type': type, ...payload};

  static Signal? parse(PublicKey from, String content) {
    try {
      final m = Map<String, Object?>.from(jsonDecode(content) as Map);
      final type = m.remove('type') as String;
      if (!const {'offer', 'answer', 'ice'}.contains(type)) return null;
      return Signal(from: from, type: type, payload: m);
    } catch (_) {
      return null;
    }
  }
}
