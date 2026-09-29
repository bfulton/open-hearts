/// Several relays, one client: listening on all of them, writing to one.
///
/// A public relay is volunteer infrastructure with rate limits and no
/// uptime promise (docs/02-multiplayer.md), and one turned on a live
/// table: six minutes into a game it began answering every event from
/// the table with a proof-of-work demand, a play that was on its way
/// reached nobody, and the seat was booted for silence. So a client
/// holds a short list. It keeps a subscription open on every relay in
/// the list and writes each event to the first that has not refused it
/// lately; a refusal moves the same event on to the next, and when
/// every relay has refused, the client is told, so a table that is cut
/// off can say so instead of looking alive. Writes cost what they did,
/// one per event; reads reach whichever relay a peer chose, since every
/// peer listens on all of them. The list's order is turned by a hash of
/// what it serves — the table id, or a key — so tables spread over the
/// relays and one relay's bad hour is not every table's.
library;

import 'relay_policy.dart';
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr.dart';

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
  /// so tables spread over them. The [pinned] at the front stay first —
  /// a relay we run, primary while up, not spun out of place with the
  /// volunteer ones.
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
  RelayConnection({required this.url, required this.subscriptions, required this.onMessage, this.log}) {
    _connect();
  }

  final Uri url;

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
    } catch (_) {}
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
    if (_closed) return;
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
    List<Object?> m;
    try {
      m = jsonDecode(raw as String) as List<Object?>;
    } catch (_) {
      return;
    }
    if (m.isEmpty) return;
    if (m[0] == 'EOSE' && !_ready.isCompleted) _ready.complete();
    onMessage(this, m);
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
  RelayGroup({required List<Uri> urls, required this.subscriptions, required this.onEvent, this.log, this.refusalMs = defaultRefusalMs}) {
    if (urls.isEmpty) throw ArgumentError('a relay group needs a relay');
    for (final u in urls) {
      connections.add(RelayConnection(url: u, subscriptions: subscriptions, onMessage: _onMessage, log: log));
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
  void publish(NostrEvent e, {bool everywhere = false, Set<Uri>? readBy}) {
    if (_closed) return;
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
