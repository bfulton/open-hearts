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

  /// A relay that stops delivering without closing the socket looks,
  /// from here, exactly like a quiet table — except that this peer's
  /// own events come back on its own subscription, so while it is
  /// publishing it should be hearing at least itself. Nothing at all
  /// for [quietMs] after publishing is a dead subscription: drop the
  /// socket and let the reconnect subscribe afresh.
  static const quietMs = 25000;
  int _lastMessageMs = 0;
  int _lastPublishMs = 0;
  Timer? _liveness;
  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;
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

  /// Lobby events for this table id — hosting, joining, starting — as
  /// they arrive. Anyone's, this peer's own included. The relay's
  /// stored history comes before [ready] resolves, so a listener that
  /// starts after that reads [lobbySoFar] first.
  Stream<NostrEvent> get lobby => _lobby.stream;

  /// Every lobby event received so far, in order.
  final List<NostrEvent> lobbySoFar = [];

  /// Publishes a lobby event, tagged with the table id: stored by the
  /// relay, or [ephemeral] — a waiting heartbeat nobody needs later.
  void announce(Map<String, Object?> content, {bool ephemeral = false}) {
    _publish(NostrEvent.sign(signer, kind: ephemeral ? TableKinds.waiting : TableKinds.lobby, content: jsonEncode(content), tags: [
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
      _lastPublishMs = _nowMs;
    } catch (_) {}
  }

  void _checkLiveness() {
    final ch = _channel;
    if (ch == null || _closed) return;
    final now = _nowMs;
    if (now - _lastPublishMs > quietMs || now - _lastMessageMs < quietMs) return;
    log?.call('nothing heard back for ${quietMs ~/ 1000} s; reconnecting');
    _channel = null;
    ch.sink.close();
    _onDropped();
  }

  void _connect() {
    if (_closed) return;
    final ch = WebSocketChannel.connect(url);
    _channel = ch;
    ch.stream.listen(_onMessage, onDone: _onDropped, onError: (_) => _onDropped());
    ch.ready.then((_) {
      if (_channel != ch) return; // dropped, or replaced, before it was ready
      _retryMs = 500;
      _lastMessageMs = _nowMs;
      _liveness ??= Timer.periodic(const Duration(seconds: 5), (_) => _checkLiveness());
      ch.sink.add(jsonEncode([
        'REQ',
        'table',
        const Filter(kinds: [TableKinds.table]).toJson()..['#t'] = [table],
        Filter(kinds: const [TableKinds.signal], tags: {'p': [signer.publicKey]}).toJson()..['#t'] = [table],
        const Filter(kinds: [TableKinds.lobby, TableKinds.waiting]).toJson()..['#t'] = [table],
      ]));
      log?.call('connected to $url');
    }).catchError((Object e) {
      log?.call('connect failed: $e');
    });
  }

  void _onDropped() {
    if (_closed) return;
    _channel = null;
    _lastMessageMs = _nowMs;
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
    _lastMessageMs = _nowMs;
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
        if (e.kind == TableKinds.lobby || e.kind == TableKinds.waiting) {
          if (e.kind == TableKinds.lobby) lobbySoFar.add(e);
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
    _liveness?.cancel();
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
