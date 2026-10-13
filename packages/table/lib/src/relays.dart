/// Several relays, one client: listening on all of them, writing to one.
///
/// Any relay can go down or start refusing a client's events, and a
/// play that reaches nobody gets its seat booted for silence. So a
/// client holds a short list (docs/explanation/relay.md). It keeps a
/// subscription open on every relay in
/// the list and writes each event to the first that has not refused it
/// lately; a refusal moves the same event on to the next, and when
/// every relay has refused, the client is told, so a table that is cut
/// off can say so instead of looking alive. Writes cost what they did,
/// one per event; reads reach whichever relay a peer chose, since every
/// peer listens on all of them. The list's order is turned by a hash of
/// what it serves — the table id, or a key — so tables spread over the
/// relays and one relay's bad hour is not every table's.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr.dart';
import 'relay_policy.dart';
import 'signing.dart';

/// What a device shows a relay that asks who it is (NIP-42), as tags
/// beside the relay's challenge in an event its key signs: the
/// activation the service gave it (licence.dart), or for the backup
/// jurors the mark the relay knows them by. Set once at
/// startup by whatever holds them; null, or null for a key, and a
/// challenge goes unanswered — a relay that asks will not carry that
/// device, which is right for one the service has not vouched for.
List<List<String>>? Function(PublicKey key)? relayCredentials;

/// Told when a relay turns this device away for good, with the
/// relay's reason: `superseded:` — another device of the account is the
/// one in use now — `suspended:` — the account is suspended from live
/// play — or `restricted:` — not admitted at all. The relay has closed
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
/// for this device: a superseded device, a suspended account's, or one
/// not admitted.
bool turnedAway(String reason) =>
    reason.startsWith('superseded:') || reason.startsWith('suspended:') || reason.startsWith('restricted:');

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
/// remakes itself when told to, and when a subscription looks dead —
/// nothing at all for [quietMs] after publishing, when this client's
/// own events should be coming back on it.
class RelayConnection {
  RelayConnection({required this.url, required this.subscriptions, required this.onMessage, this.log, this.auth}) {
    _connect();
  }

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

  static const quietMs = 25000;

  WebSocketChannel? _channel;
  bool _closed = false;
  bool _open = false;
  int _retryMs = 500;
  int _lastMessageMs = 0;
  int _lastPublishMs = 0;
  Timer? _liveness;
  final _ready = Completer<void>();

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// Up and subscribed.
  bool get connected => _open;

  /// Resolves the first time the relay acknowledges the subscriptions.
  Future<void> get ready => _ready.future;

  void publish(NostrEvent e) {
    final ch = _channel;
    if (ch == null || !_open) return;
    try {
      ch.sink.add(jsonEncode(['EVENT', e.toJson()]));
      _lastPublishMs = _nowMs;
    } on StateError catch (err) {
      // The socket closed under it; the drop reconnects, and what was
      // not sent is said again by whoever is waiting on it.
      log?.call('$url: not sent, the socket is closing: $err');
    }
  }

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
    final now = _nowMs;
    if (now - _lastPublishMs > quietMs || now - _lastMessageMs < quietMs) return;
    log?.call('$url: nothing heard back for ${quietMs ~/ 1000} s; reconnecting');
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
      _lastMessageMs = _nowMs;
      _open = true;
      for (final s in subscriptions.entries) {
        ch.sink.add(jsonEncode(['REQ', s.key, ...s.value]));
      }
      _liveness ??= Timer.periodic(const Duration(seconds: 5), (_) => _checkLiveness());
      log?.call('connected to $url');
    }).catchError((Object e) {
      log?.call('$url: connect failed: $e');
    });
  }

  void _onDropped(WebSocketChannel ch) {
    if (_closed || ch != _channel) return; // an old socket's last word
    _channel = null;
    _open = false;
    _lastMessageMs = _nowMs;
    log?.call('$url: dropped; retrying in $_retryMs ms');
    Future<void>.delayed(Duration(milliseconds: _retryMs), _connect);
    _retryMs = (_retryMs * 2).clamp(500, 10000);
  }

  void _onMessage(WebSocketChannel ch, Object? raw) {
    if (ch != _channel) return;
    _lastMessageMs = _nowMs;
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

/// A client's relays: its subscriptions on all of them, each of its
/// events written to one.
class RelayGroup {
  RelayGroup(
      {required List<Uri> urls, required this.subscriptions, required this.onEvent, this.log, this.refusalMs = defaultRefusalMs, this.auth}) {
    if (urls.isEmpty) throw ArgumentError('a relay group needs a relay');
    for (final u in urls) {
      connections.add(RelayConnection(url: u, subscriptions: subscriptions, onMessage: _onMessage, log: log, auth: auth));
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

  /// How long to wait for a relay's answer before forgetting the event.
  static const pendingMs = 15000;

  final Set<String> _seen = {};
  final Map<Uri, int> _refusedUntil = {};
  final Map<String, _Pending> _pending = {};

  /// Events written to every relay at once, and which of those relays
  /// have refused so far: a flood has no next relay to move on to, so
  /// this is how the group still learns that nobody would take it.
  final Map<String, ({Set<Uri> targets, Set<Uri> refused})> _flooded = {};

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

  /// Writes [e] to the first relay in order that is up and has not
  /// refused this client lately; a refusal moves it on to the next.
  /// Or, [everywhere], to every relay up and not refusing: for what
  /// has to be seen by a peer that can read only some of the relays —
  /// a lobby's beats, presence, a signal — one relay is not enough,
  /// since the writer cannot tell which relay a reader has lost.
  /// With [readBy], the relays the readers can read: the one relay
  /// written to is the first in order among those, and when none of
  /// them is up and taking events the event goes to every relay that
  /// is, since a relay nobody can read is no place for it.
  ///
  /// [aside]: what becomes of [e] is its own business. A relay that
  /// turns it away is not taken to be refusing this client — not kept
  /// out of the running for [refusalMs], not said under the felt — since
  /// the table waits on nothing like it: a player's reaction
  /// (reactions.dart). Gone is gone; it is not tried anywhere else.
  void publish(NostrEvent e, {bool everywhere = false, Set<Uri>? readBy, bool aside = false}) {
    if (_closed) return;
    if (aside) {
      _aside.add(e.id);
      if (_aside.length > 200) _aside.remove(_aside.first);
      for (final c in connections) {
        if (c.connected && (_refusedUntil[c.url] ?? 0) <= _nowMs) c.publish(e);
      }
      return;
    }
    final now = _nowMs;
    final upUrls = [for (final c in connections) if (c.connected && (_refusedUntil[c.url] ?? 0) <= now) c.url];
    if (floodWrite(upUrls, readBy, everywhere: everywhere)) {
      final targets = <Uri>{};
      for (final c in connections) {
        if (c.connected && (_refusedUntil[c.url] ?? 0) <= now) {
          targets.add(c.url);
          c.publish(e);
        }
      }
      if (targets.isNotEmpty) {
        _flooded[e.id] = (targets: targets, refused: <Uri>{});
      } else {
        _answer(e.id, false);
      }
      return;
    }
    if (readBy == null) return _send(e, const {}, null);
    _send(e, {for (final c in connections) if (!readBy.contains(c.url)) c.url}, null);
  }

  /// The relays this group is connected to right now.
  Set<Uri> get reading => {for (final c in connections) if (c.connected) c.url};

  void _send(NostrEvent e, Set<Uri> tried, String? lastReason) {
    if (_closed) return;
    final now = _nowMs;
    for (final c in connections) {
      if (!c.connected || tried.contains(c.url) || (_refusedUntil[c.url] ?? 0) > now) continue;
      _pending[e.id] = _Pending(e, {...tried, c.url}, now);
      c.publish(e);
      return;
    }
    // Nothing up, or every relay up refusing: the event goes nowhere —
    // the protocol repeats what matters, and while a refusal lasts a
    // write would only be refused again. Refused everywhere just now
    // is worth saying; refused earlier is already said.
    _answer(e.id, false);
    if (lastReason != null) _setRefusal(lastReason);
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
        final p = _pending.remove(id);
        final flood = _flooded[id];
        if (taken) {
          _refusedUntil.remove(from.url);
          _flooded.remove(id);
          _answer(id, true);
          _setRefusal(null);
          return;
        }
        log?.call('${from.url} refused ${id.substring(0, 8)}: $reason');
        _refusedUntil[from.url] = _nowMs + refusalMs;
        if (flood != null) {
          // A flood has no next relay to try. It is worth saying only
          // when every relay it went to has refused it: then nothing
          // this device writes is getting out, which is the one thing
          // the player can act on.
          flood.refused.add(from.url);
          if (flood.refused.containsAll(flood.targets)) {
            _flooded.remove(id);
            _answer(id, false);
            _setRefusal(reason);
          }
          return;
        }
        // Sent to one relay: on to the next. Given up on: the others
        // have it.
        if (p != null) _send(p.event, p.tried, reason);
      case 'NOTICE':
        log?.call('${from.url}: ${m.length > 1 ? m[1] : ''}');
    }
  }

  void _sweep() {
    final now = _nowMs;
    _pending.removeWhere((_, p) => now - p.sentMs > pendingMs);
    if (_flooded.length > 200) _flooded.clear();
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

class _Pending {
  _Pending(this.event, this.tried, this.sentMs);
  final NostrEvent event;
  final Set<Uri> tried;
  final int sentMs;
}
