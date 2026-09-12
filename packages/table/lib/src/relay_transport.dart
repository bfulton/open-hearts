/// A [Transport] over relays, and the signalling that WebRTC needs on
/// the same wire.
///
/// Every message the table broadcasts goes to a relay as an ephemeral
/// event of kind [TableKinds.table], tagged with the table id and
/// signed by this peer, with the message as its content. Everyone at
/// the table subscribes to that kind and tag on every relay in the
/// list and writes to one of them (relays.dart). What arrives is
/// stamped `from` the event's signer — the peer that sent it, which
/// for a relayed message is not its author — and that is the
/// distinction the protocol's "heard from" depends on.
///
/// A relay is a meeting point, not a friend: it says nothing when a peer
/// goes, so [disconnected] never fires here. The protocol's heartbeats
/// carry that.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'nip44.dart';
import 'nostr.dart';
import 'relays.dart';
import 'signing.dart';
import 'transport.dart';

class RelayTransport implements Transport {
  RelayTransport({required List<Uri> relays, required this.signer, required this.table, this.log, int refusalMs = RelayGroup.defaultRefusalMs})
      : relays = Relays.turnedBy(relays, table) {
    _group = RelayGroup(
      urls: this.relays,
      refusalMs: refusalMs,
      subscriptions: {
        'table': [
          const Filter(kinds: [TableKinds.table]).toJson()..['#t'] = [table],
          Filter(kinds: const [TableKinds.signal], tags: {
            'p': [signer.publicKey]
          }).toJson()
            ..['#t'] = [table],
          const Filter(kinds: [TableKinds.lobby, TableKinds.waiting]).toJson()..['#t'] = [table],
        ],
      },
      onEvent: _onEvent,
      log: log,
    );
  }

  /// The relays, in the order this table writes to them.
  final List<Uri> relays;
  final Signer signer;
  final String table;
  final void Function(String line)? log;

  late final RelayGroup _group;
  final _incoming = StreamController<({PublicKey from, Map<String, Object?> message})>.broadcast();
  final _disconnected = StreamController<PublicKey>.broadcast();
  final _signals = StreamController<Signal>.broadcast();
  final _lobby = StreamController<NostrEvent>.broadcast();

  /// Resolves once some relay has acknowledged the subscription.
  Future<void> get ready => _group.ready;

  /// Resolves once every relay has — for a reader of stored events,
  /// each relay holding the share written to it.
  Future<void> get allReady => _group.allReady;

  /// The reason the last relay gave when every relay refused this
  /// peer's latest event; null once one takes an event again.
  String? get refusal => _group.refusal;

  /// [refusal] as it changes.
  Stream<String?> get refusals => _group.refusals;

  @override
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming => _incoming.stream;

  @override
  Stream<PublicKey> get disconnected => _disconnected.stream;

  /// Offers, answers and candidates addressed to this peer.
  Stream<Signal> get signals => _signals.stream;

  /// Lobby events for this table id — hosting, joining, starting — as
  /// they arrive. Anyone's, this peer's own included. A relay's stored
  /// history comes before [ready] resolves, so a listener that starts
  /// after that reads [lobbySoFar] first; what the other relays hold
  /// follows as it arrives.
  Stream<NostrEvent> get lobby => _lobby.stream;

  /// Every lobby event received so far, in order.
  final List<NostrEvent> lobbySoFar = [];

  /// Publishes a lobby event, tagged with the table id: stored by the
  /// relay, or [ephemeral] — a waiting heartbeat nobody needs later.
  void announce(Map<String, Object?> content, {bool ephemeral = false}) {
    _group.publish(NostrEvent.sign(signer, kind: ephemeral ? TableKinds.waiting : TableKinds.lobby, content: jsonEncode(content), tags: [
      ['t', table],
    ]));
  }

  @override
  void broadcast(Map<String, Object?> message) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.table, content: jsonEncode(message), tags: [
      ['t', table],
    ]));
  }

  /// Sends one signalling message to [to], sealed to its key: an
  /// offer or a candidate carries an address, and a public relay
  /// carries the event.
  void signal(PublicKey to, Signal s) {
    final String content;
    try {
      content = Nip44.encrypt(_conversationKeyWith(to), jsonEncode(s.toJson()));
    } on ArgumentError {
      log?.call('no sealing a signal to ${to.substring(0, 6)}: not a key');
      return;
    }
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.signal, content: content, tags: [
      ['p', to],
      ['t', table],
    ]));
  }

  final Map<PublicKey, Uint8List> _conversationKeys = {};

  /// The NIP-44 conversation key with [other], made once.
  Uint8List _conversationKeyWith(PublicKey other) =>
      _conversationKeys.putIfAbsent(other, () => Nip44.conversationKey(signer.sharedXWith(other)));

  /// One event, from whichever relay delivered it first. A table
  /// event's envelope signature is not checked here: the relay checked
  /// it before carrying the event, what the envelope carries is signed
  /// by the same key and checked by the client, and every signature
  /// checked is milliseconds a peer flooded with repeats has not got —
  /// a juror behind a whole hand drowned in them. Every other kind is
  /// checked. False for what fails, so the id is not remembered and
  /// the real event under it still gets in.
  bool _onEvent(Map<String, Object?> raw) {
    final e = NostrEvent.parse(raw, verifySignature: raw['kind'] != TableKinds.table);
    if (e == null || e.tag('t') != table) return false;
    if (e.kind == TableKinds.lobby || e.kind == TableKinds.waiting) {
      if (e.kind == TableKinds.lobby) lobbySoFar.add(e);
      _lobby.add(e);
      return true;
    }
    if (e.pubkey == signer.publicKey) return true;
    if (e.kind == TableKinds.table) {
      try {
        final message = Map<String, Object?>.from(jsonDecode(e.content) as Map);
        _incoming.add((from: e.pubkey, message: message));
      } catch (_) {}
    } else if (e.kind == TableKinds.signal && e.tag('p') == signer.publicKey) {
      final String text;
      try {
        text = Nip44.decrypt(_conversationKeyWith(e.pubkey), e.content);
      } catch (_) {
        log?.call('a signal from ${e.pubkey.substring(0, 6)} that does not open');
        return true;
      }
      final s = Signal.parse(e.pubkey, text);
      if (s != null) _signals.add(s);
    }
    return true;
  }

  @override
  void close() {
    _group.close();
    _incoming.close();
    _disconnected.close();
    _signals.close();
    _lobby.close();
  }
}

/// One WebRTC signalling message: an offer or answer carrying SDP, or
/// an ICE candidate. On the wire it is sealed to the recipient's key
/// (NIP-44, nip44.dart): a candidate carries an address, and a public
/// relay carries the event.
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
