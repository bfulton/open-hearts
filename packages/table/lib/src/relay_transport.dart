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
/// goes, so `disconnected` never fires here. The protocol's heartbeats
/// carry that.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'nip44.dart';
import 'nostr.dart';
import 'presence_relay.dart' show relaysForTag;
import 'reactions.dart';
import 'relay_policy.dart';
import 'relays.dart';
import 'signing.dart';
import 'transport.dart';

class RelayTransport implements Transport, ReactionLane {
  RelayTransport(
      {required List<Uri> relays,
      required this.signer,
      required this.table,
      this.log,
      int pinned = 0,
      int refusalMs = RelayGroup.defaultRefusalMs,
      bool watchOnly = false})
      : relays = Relays.turnedBy(relaysForTag(relays, table), table, pinned: pinned) {
    // The watch lane, and the players' reactions beside it: both are for
    // anyone looking at the table, watching it or seated at it.
    final watch = const Filter(kinds: [TableKinds.watch, TableKinds.react]).toJson()..['#t'] = [table];
    _group = RelayGroup(
      urls: this.relays,
      refusalMs: refusalMs,
      auth: relayAuthFor(signer),
      // Someone watching (watch.dart) reads the watch lane, with the
      // players' reactions on it, and nothing else: not the table's own
      // traffic, which is not theirs to carry.
      subscriptions: watchOnly ? {'watch': [watch]} : {
        'table': [
          watch,
          const Filter(kinds: [TableKinds.table]).toJson()..['#t'] = [table],
          Filter(kinds: const [TableKinds.signal], tags: {
            'p': [signer.publicKey]
          }).toJson()
            ..['#t'] = [table],
          Filter(kinds: const [TableKinds.lobby, TableKinds.waiting], since: _lobbySince(table)).toJson()..['#t'] = [table],
        ],
      },
      onEvent: _onEvent,
      log: log,
    );
  }

  /// What a pool's tag starts with (matching.dart, poolTag).
  static const poolPrefix = 'queue:';

  /// How far back a pool's seatings are worth reading. A seating is for
  /// its own round of a few seconds and ignored after it, and the
  /// rounds are cut by each device's own clock, so the pool already
  /// takes the clocks to agree within one; a minute is that with room
  /// to spare.
  static const poolHistorySeconds = 60;

  /// Where the stored lobby events start for [tag]: a pool's from a
  /// minute ago, a room code's from the beginning.
  ///
  /// Every seating is stored, because a room code's joiner has to be
  /// handed the room announced before it arrived — that history is the
  /// point of a room. A pool's is not: its seatings pile up round after
  /// round, each useless the moment its round is over.
  static int? _lobbySince(String tag) =>
      tag.startsWith(poolPrefix) ? DateTime.now().millisecondsSinceEpoch ~/ 1000 - poolHistorySeconds : null;

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
  final _watch = StreamController<({PublicKey from, Map<String, Object?> content})>.broadcast();
  final _reactions = StreamController<HeardReaction>.broadcast();

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

  @override
  bool get cutOff => _group.cutOff;

  /// The line to the relays, in a few words ([RelayGroup.health]).
  String get health => _group.health;

  /// Offers, answers and candidates addressed to this peer.
  Stream<Signal> get signals => _signals.stream;

  /// Lobby events for this table id — hosting, joining, starting — as
  /// they arrive. Anyone's, this peer's own included. A relay's stored
  /// history comes before [ready] resolves, so a listener that starts
  /// after that reads [lobbySoFar] first; what the other relays hold
  /// follows as it arrives.
  Stream<NostrEvent> get lobby => _lobby.stream;

  /// The watch lane (watch.dart): a watcher saying it is there, a
  /// player's view of the table — stamped with who signed it.
  Stream<({PublicKey from, Map<String, Object?> content})> get watch => _watch.stream;

  /// Says [content] on the watch lane, on every relay: a watcher reads
  /// whichever it reaches.
  void sayWatch(Map<String, Object?> content) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.watch, content: jsonEncode(content), tags: [
      ['t', table],
    ]), everywhere: true);
  }

  /// Says a reaction (reactions.dart) on every relay, as the watch lane
  /// is said: a watcher reads whichever it reaches. A relay that turns
  /// it away is not taken to be refusing the table's own events
  /// ([RelayGroup.publish], `aside`) — a reaction is nothing the table
  /// waits on.
  @override
  void sayReaction(String content) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.react, content: content, tags: [
      ['t', table],
    ]), everywhere: true, aside: true);
  }

  /// Everyone else's reactions, as they arrive, not yet believed: the
  /// screen holds each to [ReactionRules].
  @override
  Stream<HeardReaction> get reactions => _reactions.stream;

  /// Every lobby event received so far, in order.
  final List<NostrEvent> lobbySoFar = [];

  /// Publishes a lobby event, tagged with the table id: stored by the
  /// relay, or [ephemeral] — a waiting heartbeat nobody needs later.
  /// To every relay, not one: a room forms from who hears whom, and a
  /// peer that has lost one relay must still hear this device on the
  /// others, or two tables start under one code.
  void announce(Map<String, Object?> content, {bool ephemeral = false}) {
    _group.publish(_lobbyEvent(content, ephemeral: ephemeral), everywhere: true);
  }

  /// [announce]d and stored, and whether a relay took it: true once one
  /// has, false once every relay it went to refused it, or none was up,
  /// or [within] ran out. For what must not go nowhere quietly: a
  /// game's result.
  Future<bool> announceTaken(Map<String, Object?> content, {Duration within = const Duration(seconds: 10)}) {
    final e = _lobbyEvent(content);
    final taken = _group.taken(e.id, within: within);
    _group.publish(e, everywhere: true);
    return taken;
  }

  NostrEvent _lobbyEvent(Map<String, Object?> content, {bool ephemeral = false}) =>
      NostrEvent.sign(signer, kind: ephemeral ? TableKinds.waiting : TableKinds.lobby, content: jsonEncode(content), tags: [
        ['t', table],
      ]);

  @override
  void broadcast(Map<String, Object?> message, {bool everywhere = false}) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.table, content: jsonEncode(message), tags: [
      ['t', table],
    ]), everywhere: everywhere, readBy: everywhere ? null : _readBy());
  }

  @override
  List<String> get paths => [for (final u in _group.reading) u.toString()];

  /// What each peer last said it reads, and when: a peer not heard
  /// from in two minutes is out of the reckoning, as it is out of the
  /// table's.
  final Map<PublicKey, ({Set<Uri> reads, int at})> _peerReads = {};

  @override
  void heard(PublicKey peer, List<String> paths) {
    final reads = <Uri>{};
    for (final p in paths) {
      final u = Uri.tryParse(p);
      if (u != null) reads.add(u);
    }
    if (reads.isEmpty) return; // a peer with nothing to say about it
    _peerReads[peer] = (reads: reads, at: DateTime.now().millisecondsSinceEpoch);
  }

  /// The relays every peer heard from lately reads; null when no peer
  /// has said, so the writer's own order decides.
  Set<Uri>? _readBy() => readByFrom(_peerReads, DateTime.now().millisecondsSinceEpoch, 120000);

  /// Sends one signalling message to [to], sealed to its key: an
  /// offer or a candidate carries an address, and a relay carries the
  /// event — every relay, since a peer that cannot read
  /// one of them still has to be reached, and there are a dozen of
  /// these a table.
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
    ]), everywhere: true);
  }

  final Map<PublicKey, Uint8List> _conversationKeys = {};

  /// The NIP-44 conversation key with [other], made once.
  Uint8List _conversationKeyWith(PublicKey other) =>
      _conversationKeys.putIfAbsent(other, () => Nip44.conversationKey(signer.sharedXWith(other)));

  /// One event, from whichever relay delivered it first. A table
  /// event's envelope signature is not checked here: the relay checked
  /// it before carrying the event, what the envelope carries is signed
  /// by the same key and checked by the client, and every signature
  /// checked is milliseconds a peer flooded with repeats has not got.
  /// Every other kind is checked. False for what fails, so the id is
  /// not remembered and
  /// the real event under it still gets in.
  bool _onEvent(Map<String, Object?> raw) {
    // A reaction nobody here shows — a juror's client, say — is not
    // worth its signature.
    if (raw['kind'] == TableKinds.react && !_reactions.hasListener) return true;
    final e = NostrEvent.parse(raw, verifySignature: raw['kind'] != TableKinds.table);
    if (e == null || e.tag('t') != table) return false;
    if (e.kind == TableKinds.lobby || e.kind == TableKinds.waiting) {
      if (e.kind == TableKinds.lobby) lobbySoFar.add(e);
      _lobby.add(e);
      return true;
    }
    if (e.pubkey == signer.publicKey) return true;
    if (e.kind == TableKinds.watch) {
      try {
        _watch.add((from: e.pubkey, content: Map<String, Object?>.from(jsonDecode(e.content) as Map)));
      } catch (_) {}
    } else if (e.kind == TableKinds.react) {
      _reactions.add((from: e.pubkey, id: e.id, createdAt: e.createdAt, content: e.content));
    } else if (e.kind == TableKinds.table) {
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
  void reach(Set<PublicKey> peers) {
    // A relay reaches whoever reads it; there is nobody to dial.
  }

  @override
  void close() {
    _group.close();
    _incoming.close();
    _disconnected.close();
    _signals.close();
    _lobby.close();
    _watch.close();
    _reactions.close();
  }
}

/// One WebRTC signalling message: an offer or answer carrying SDP, or
/// an ICE candidate. On the wire it is sealed to the recipient's key
/// (NIP-44, nip44.dart): a candidate carries an address, and a relay
/// carries the event.
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
