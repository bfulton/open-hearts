/// A client's sockets to the relays in its list: one relay, ours, in a
/// deployed build (docs/explanation/relay.md), though a test or the
/// remote config may name more.
///
/// The client keeps its subscriptions open on every relay in the list
/// and writes each event to every one that is up. A relay that refuses
/// an event is kept out of the running for a while
/// ([RelayGroup.refusalMs]), and when every relay an event went to has
/// refused it, the client is told, so a table that is cut off can say
/// so instead of looking alive.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr.dart';
import 'signing.dart';

/// How long a device may hear nothing at all, with something it sent
/// waiting on an answer, before it takes its socket for dead and makes
/// it again. Our relay answers everything it is sent, so ten seconds of
/// nothing is the line down.
const unansweredMs = 10000;

/// How long an answer may take on a slow line: something sent waits
/// this long before its going unanswered counts at all.
const answerMs = 3000;

/// What a device shows a relay that asks who it is (NIP-42), as tags
/// beside the relay's challenge in an event its key signs: the
/// activation the service gave it (licence.dart), or for the house
/// nothing beside the challenge: the relay knows it by its key. Set
/// once at startup by whatever holds them; null, or null for a key, and a
/// challenge goes unanswered — a relay that asks will not carry that
/// device, which is right for one the service has not vouched for.
List<List<String>>? Function(PublicKey key)? relayCredentials;

/// Told when a relay turns this device away for good, with the
/// relay's reason: `superseded:` — another device of the account is the
/// one in use now — `suspended:` — the account is suspended from live
/// play — or `deleted:` — the account was deleted. The relay has closed
/// or will close the socket, and retrying will not change its mind
/// (docs/explanation/service.md, "One device at a time").
void Function(String reason)? relayTurnedAway;

/// How [signer] answers a relay's challenge: the AUTH event, or null
/// when this process has nothing to show for it.
NostrEvent? Function(Uri relay, String challenge) relayAuthFor(Signer signer) => (relay, challenge) {
      final shown = relayCredentials?.call(signer.publicKey);
      if (shown == null) return null;
      return NostrEvent.sign(signer, kind: TableKinds.auth, content: '', tags: [
        ['relay', '$relay'],
        ['challenge', challenge],
        ...shown,
      ]);
    };

/// Whether a relay's reason is one it will not change its mind about
/// for this device: a superseded device, or a suspended or deleted
/// account's.
bool turnedAway(String reason) =>
    reason.startsWith('superseded:') ||
    reason.startsWith('suspended:') ||
    reason.startsWith('deleted:');

/// The list itself: parsed from text, turned by a key.
abstract final class Relays {
  /// `wss://a, wss://b` — commas, spaces or newlines between.
  static List<Uri> parse(String text) => [
        for (final s in text.split(RegExp(r'[,\s]+')))
          if (s.isNotEmpty) Uri.parse(s),
      ];

  static String format(List<Uri> relays) => relays.join(', ');

  /// The relays past the first [pinned] begun at the entry a hash of
  /// [key] picks, the rest following in order: where a client writes
  /// first among the interchangeable relays is a function of the table,
  /// so tables spread over them. The [pinned] at the front stay first:
  /// a primary relay, not spun out of place with the rest.
  static List<Uri> turnedBy(List<Uri> relays, String key, {int pinned = 0}) {
    if (relays.length - pinned < 2) return relays;
    final tail = relays.sublist(pinned);
    // FNV-1a over the key's code units: the same on every platform,
    // which String.hashCode is not.
    var h = 0x811c9dc5;
    for (final u in key.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0xffffffff;
    }
    final k = h % tail.length;
    return [...relays.sublist(0, pinned), ...tail.sublist(k), ...tail.sublist(0, k)];
  }
}

/// One socket to one relay. Connects, sends its subscriptions, hands
/// every message up; reconnects with a growing pause when dropped;
/// remakes itself when told to, and when its line looks down ([cutOff]):
/// nothing at all heard for [unansweredMs] with something sent waiting
/// on an answer, from a relay that answers everything it is sent — an
/// event with OK, a subscription with the end of what it holds.
class RelayConnection {
  RelayConnection(
      {required this.url,
      required this.subscriptions,
      required this.onMessage,
      this.log,
      this.auth,
      this.onOpen,
      this.onIdle,
      this.cutOffMs = unansweredMs,
      this.answerWaitMs = answerMs}) {
    _connect();
  }

  /// Told each time the socket drops.
  void Function(RelayConnection connection)? onDropped;

  /// Told each time a socket opens, after the subscriptions are sent:
  /// for what else a new socket has to say first.
  final void Function(RelayConnection connection)? onOpen;

  /// Told when the relay has said nothing for half of [cutOffMs] and
  /// nothing sent is waiting on its answer: for something to ask that
  /// the relay answers. A line whose way in has stalled is found out
  /// only by what goes unanswered ([cutOff]), and a side waiting on
  /// others has nothing else to say.
  final void Function(RelayConnection connection)? onIdle;

  /// Sends [message] as it is, if the socket is open: false where it is
  /// not, and whoever is waiting on it says it again on the next.
  bool sendRaw(List<Object?> message) {
    final ch = _channel;
    if (ch == null || !_open) return false;
    try {
      ch.sink.add(jsonEncode(message));
      _unansweredSince ??= _nowMs;
      return true;
    } on StateError catch (err) {
      log?.call('$url: not sent, the socket is closing: $err');
      return false;
    }
  }

  /// [unansweredMs] and [answerMs], shorter in a test.
  final int cutOffMs, answerWaitMs;

  final Uri url;

  /// How this connection answers the relay's challenge, if it asks
  /// ([relayAuthFor]). A relay that asks holds whatever was said before
  /// the answer until it has checked it, so nothing here waits.
  final NostrEvent? Function(Uri relay, String challenge)? auth;

  /// Turned away for good ([turnedAway]): not connected again.
  bool _refused = false;

  /// Subscription id to filters, as JSON; sent on every connection.
  final Map<String, List<Map<String, Object?>>> subscriptions;

  /// Every message the relay sends, decoded.
  final void Function(RelayConnection from, List<Object?> message) onMessage;
  final void Function(String line)? log;

  WebSocketChannel? _channel;
  bool _closed = false;
  bool _open = false;
  int _retryMs = 500;

  /// When the relay last said anything, the opening of a socket
  /// included; 0 before it ever has.
  int _heardMs = 0;

  /// When the oldest of what this connection has sent since the relay
  /// last said anything went; null while nothing is waiting on it.
  int? _unansweredSince;
  Timer? _liveness;
  final _ready = Completer<void>();

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// Up and subscribed.
  bool get connected => _open;

  /// Whether this connection is down, or as good as: not open, or open
  /// with nothing heard for [cutOffMs] while what it sent has waited
  /// longer than an answer takes ([answerWaitMs]). A relay answers
  /// everything, so that silence is the line, not the table — and on a
  /// line whose way in has stalled while its way out still carries, the
  /// socket looks open for as long as the stall lasts.
  bool get cutOff {
    if (!_open) return true;
    final since = _unansweredSince;
    final now = _nowMs;
    return since != null && now - since >= answerWaitMs && now - _heardMs >= cutOffMs;
  }

  /// How long since the relay last said anything; null if it never has.
  int? get heardAgoMs => _heardMs == 0 ? null : _nowMs - _heardMs;

  /// How often the socket has dropped, and how often of those this
  /// connection dropped it itself for a relay gone silent ([cutOff]):
  /// for the account of a game lost to the line.
  int get drops => _drops;
  int get silences => _silences;
  int _drops = 0, _silences = 0;

  /// Resolves the first time the relay acknowledges the subscriptions.
  Future<void> get ready => _ready.future;

  void publish(NostrEvent e) => sendRaw(['EVENT', e.toJson()]);

  /// Drops the socket and connects afresh: a relay that turned on this
  /// client's connection may take a new one.
  void remake() {
    final ch = _channel;
    if (ch == null || _closed) return;
    _onDropped(ch);
    ch.sink.close();
  }

  void _checkLiveness() {
    final ch = _channel;
    if (ch == null || _closed || !_open) return;
    if (!cutOff) {
      if (_unansweredSince == null && _nowMs - _heardMs >= cutOffMs ~/ 2) onIdle?.call(this);
      return;
    }
    log?.call('$url: nothing heard for ${(_nowMs - _heardMs) ~/ 1000} s, with what was sent unanswered; reconnecting');
    _silences++;
    remake();
  }

  void _connect() {
    if (_closed || _refused) return;
    final ch = WebSocketChannel.connect(url);
    _channel = ch;
    ch.stream.listen((m) => _onMessage(ch, m), onDone: () => _onDropped(ch), onError: (_) => _onDropped(ch));
    ch.ready.then((_) {
      if (_channel != ch) return; // dropped, or replaced, before it was ready
      _retryMs = 500;
      _heardMs = _nowMs;
      _open = true;
      // Each subscription is answered with the end of what the relay
      // holds for it: the first answer this socket waits on.
      _unansweredSince = subscriptions.isEmpty ? null : _nowMs;
      for (final s in subscriptions.entries) {
        ch.sink.add(jsonEncode(['REQ', s.key, ...s.value]));
      }
      _liveness ??= Timer.periodic(Duration(milliseconds: cutOffMs ~/ 5), (_) => _checkLiveness());
      log?.call('connected to $url');
      onOpen?.call(this);
    }).catchError((Object e) {
      log?.call('$url: connect failed: $e');
    });
  }

  void _onDropped(WebSocketChannel ch) {
    if (_closed || ch != _channel) return; // an old socket's last word
    _channel = null;
    _open = false;
    _unansweredSince = null;
    _drops++;
    onDropped?.call(this);
    log?.call('$url: dropped; retrying in $_retryMs ms');
    Future<void>.delayed(Duration(milliseconds: _retryMs), _connect);
    _retryMs = (_retryMs * 2).clamp(500, 10000);
  }

  void _onMessage(WebSocketChannel ch, Object? raw) {
    if (ch != _channel) return;
    _heardMs = _nowMs;
    _unansweredSince = null;
    if (raw is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      log?.call('$url: a message that is not JSON');
      return;
    }
    if (decoded is! List<Object?>) return;
    final m = decoded;
    if (m.isEmpty) return;
    if (m[0] == 'EOSE' && !_ready.isCompleted) _ready.complete();
    if (m[0] == 'AUTH' && m.length > 1 && m[1] is String) {
      final answer = auth?.call(url, m[1] as String);
      if (answer != null) {
        _authId = answer.id;
        try {
          ch.sink.add(jsonEncode(['AUTH', answer.toJson()]));
        } on StateError catch (err) {
          log?.call('$url: no answer to its challenge, the socket is closing: $err');
        }
      }
      return;
    }
    // The answer to this connection's own AUTH is the relay's to give,
    // and its refusal for good is the device's to hear.
    if (m[0] == 'OK' && m.length > 3 && m[1] == _authId) {
      if (m[2] == true) return;
      final reason = '${m[3]}';
      if (turnedAway(reason)) return _turnedAway(reason);
      // Not now — an activation run out, say, while the device slept:
      // a fresh socket in a few seconds answers with whatever it holds
      // by then.
      log?.call('$url: not carried yet: $reason');
      Future<void>.delayed(const Duration(seconds: 5), remake);
      return;
    }
    if ((m[0] == 'NOTICE' || m[0] == 'CLOSED') && m.length > 1 && turnedAway('${m.last}')) _turnedAway('${m.last}');
    onMessage(this, m);
  }

  String? _authId;

  void _turnedAway(String reason) {
    if (!turnedAway(reason)) return;
    log?.call('$url: turned away: $reason');
    _refused = true;
    relayTurnedAway?.call(reason);
  }

  void close() {
    _closed = true;
    _liveness?.cancel();
    _channel?.sink.close();
    _channel = null;
    _open = false;
  }
}

/// A client's relays: its subscriptions on all of them, and each of its
/// events written to all of them.
class RelayGroup {
  RelayGroup(
      {required List<Uri> urls,
      required this.subscriptions,
      required this.onEvent,
      this.log,
      this.refusalMs = defaultRefusalMs,
      this.auth,
      int cutOffMs = unansweredMs,
      int answerWaitMs = answerMs}) {
    if (urls.isEmpty) throw ArgumentError('a relay group needs a relay');
    for (final u in urls) {
      connections.add(RelayConnection(
          url: u,
          subscriptions: subscriptions,
          onMessage: _onMessage,
          log: log,
          auth: auth,
          cutOffMs: cutOffMs,
          answerWaitMs: answerWaitMs));
    }
    ready = Future.any([for (final c in connections) c.ready]);
    allReady = Future.wait([for (final c in connections) c.ready]);
    _sweeper = Timer.periodic(const Duration(seconds: 5), (_) => _sweep());
  }

  /// Subscription id to filters, as JSON.
  final Map<String, List<Map<String, Object?>>> subscriptions;

  /// Every event once, raw, whichever relay delivered it first. Returns
  /// whether it was taken: an event that fails its owner's checks is
  /// not remembered, so the real one under that id still gets in.
  final bool Function(Map<String, Object?> raw) onEvent;
  final void Function(String line)? log;

  /// How each connection answers a relay that asks who it is.
  final NostrEvent? Function(Uri relay, String challenge)? auth;

  final List<RelayConnection> connections = [];

  /// Resolves once some relay has acknowledged the subscriptions.
  late final Future<void> ready;

  /// Resolves once every relay has: for a reader of stored events, of
  /// which each relay holds the share written to it.
  late final Future<void> allReady;

  /// How long a refusal keeps a relay out of the running: a minute,
  /// less in a test.
  final int refusalMs;
  static const defaultRefusalMs = 60000;

  final Set<String> _seen = {};
  final Map<Uri, int> _refusedUntil = {};

  /// Events written, and which of the relays each went to have refused
  /// it so far: how the group learns that nobody would take one.
  final Map<String, ({Set<Uri> targets, Set<Uri> refused})> _sent = {};

  /// Waiting to hear whether an event was taken: see [taken].
  final Map<String, Completer<bool>> _taking = {};

  /// Events published [publish] `aside`, whose refusal is nobody's
  /// business but theirs: the newest few hundred, oldest first.
  final _aside = <String>{};
  final _refusals = StreamController<String?>.broadcast();
  String? _refusal;
  Timer? _sweeper;
  bool _closed = false;

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  bool get connected => connections.any((c) => c.connected);

  /// Whether this client is cut off from every relay
  /// ([RelayConnection.cutOff]): what it does not hear then is its own
  /// line, not the table.
  bool get cutOff => connections.every((c) => c.cutOff);

  /// The line as it stands, in a few words for an account of a game
  /// lost to it: how many relays are open of how many, when one was
  /// last heard, and how often the sockets dropped and of those were
  /// dropped for silence.
  String get health {
    final open = connections.where((c) => c.connected).length;
    final heard = [for (final c in connections) c.heardAgoMs].whereType<int>();
    final last = heard.isEmpty ? 'never heard' : 'heard ${heard.reduce((a, b) => a < b ? a : b)} ms ago';
    var drops = 0, silences = 0;
    for (final c in connections) {
      drops += c.drops;
      silences += c.silences;
    }
    return '$open of ${connections.length} open${cutOff ? ', cut off' : ''}; $last; dropped $drops, for silence $silences';
  }

  /// The reason the last relay gave when every relay refused this
  /// client's latest event; null once one takes an event again.
  String? get refusal => _refusal;

  /// [refusal] as it changes.
  Stream<String?> get refusals => _refusals.stream;

  /// Whether a relay takes the event [id]: true once one stores it, or
  /// says it had it already; false once every relay it went to has
  /// refused it, or none was up to take it, or [within] runs out first.
  /// Asked before the event is published, so no answer can arrive
  /// before anybody is listening for it.
  Future<bool> taken(String id, {required Duration within}) {
    final waiting = _taking.putIfAbsent(id, Completer<bool>.new);
    return waiting.future.timeout(within, onTimeout: () {
      _taking.remove(id);
      return false;
    });
  }

  void _answer(String id, bool taken) => _taking.remove(id)?.complete(taken);

  /// Writes [e] to every relay that is up and has not refused this
  /// client lately. With none, the event goes nowhere: the protocol
  /// repeats what matters, and while a refusal lasts a write would only
  /// be refused again.
  ///
  /// [aside]: what becomes of [e] is its own business. A relay that
  /// turns it away is not taken to be refusing this client — not kept
  /// out of the running for [refusalMs], not said under the felt — since
  /// the table waits on nothing like it: a player's reaction
  /// (reactions.dart).
  void publish(NostrEvent e, {bool aside = false}) {
    if (_closed) return;
    final now = _nowMs;
    final up = [for (final c in connections) if (c.connected && (_refusedUntil[c.url] ?? 0) <= now) c];
    for (final c in up) {
      c.publish(e);
    }
    if (aside) {
      _aside.add(e.id);
      if (_aside.length > 200) _aside.remove(_aside.first);
    } else if (up.isEmpty) {
      _answer(e.id, false);
    } else {
      _sent[e.id] = (targets: {for (final c in up) c.url}, refused: <Uri>{});
    }
  }

  void _setRefusal(String? reason) {
    if (_refusal == reason) return;
    _refusal = reason;
    if (!_refusals.isClosed) _refusals.add(reason);
  }

  void _onMessage(RelayConnection from, List<Object?> m) {
    switch (m[0]) {
      case 'EVENT':
        if (m.length != 3) return;
        final raw = m[2];
        if (raw is! Map) return;
        final id = raw['id'];
        if (id is! String || _seen.contains(id)) return;
        if (!onEvent(Map<String, Object?>.from(raw))) return;
        _seen.add(id);
        if (_seen.length > 50000) _seen.clear();
      case 'OK':
        if (m.length < 3 || m[1] is! String) return;
        final id = m[1] as String;
        final reason = m.length > 3 ? '${m[3]}' : '';
        final taken = m[2] == true || reason.startsWith('duplicate:');
        // Every relay it went to answers for itself, so it stays marked
        // until the newest few hundred have pushed it out.
        if (_aside.contains(id)) {
          if (!taken) log?.call('${from.url} refused ${id.substring(0, 8)}, said aside: $reason');
          return;
        }
        final sent = _sent[id];
        if (taken) {
          _refusedUntil.remove(from.url);
          _sent.remove(id);
          _answer(id, true);
          _setRefusal(null);
          return;
        }
        log?.call('${from.url} refused ${id.substring(0, 8)}: $reason');
        _refusedUntil[from.url] = _nowMs + refusalMs;
        // Worth saying only when every relay it went to has refused it:
        // then nothing this device writes is getting out, which is the
        // one thing the player can act on.
        if (sent == null) return;
        sent.refused.add(from.url);
        if (sent.refused.containsAll(sent.targets)) {
          _sent.remove(id);
          _answer(id, false);
          _setRefusal(reason);
        }
      case 'NOTICE':
        log?.call('${from.url}: ${m.length > 1 ? m[1] : ''}');
    }
  }

  void _sweep() {
    final now = _nowMs;
    if (_sent.length > 200) _sent.clear();
    // A relay's refusal has run out: a fresh connection, since one
    // that turned on this client may not turn back, and the next event
    // will try it.
    for (final c in connections) {
      final until = _refusedUntil[c.url];
      if (until == null || until > now) continue;
      _refusedUntil.remove(c.url);
      c.remake();
    }
  }

  void close() {
    _closed = true;
    _sweeper?.cancel();
    for (final waiting in _taking.values) {
      waiting.complete(false);
    }
    _taking.clear();
    for (final c in connections) {
      c.close();
    }
    _refusals.close();
  }
}
