/// Presence over the relay: who is online, and a summons to a juror.
///
/// Every client with the app open says so on one well-known tag every
/// few seconds — an ephemeral event, forwarded and forgotten — and
/// everyone listening keeps a map of who was heard when. A summons is
/// an event on the same tag addressed to one key, carrying the table's
/// spec and the hand; a juror of last resort listens for a table's
/// call on the tag as well. One socket, apart from any table's.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'jury.dart';
import 'nostr.dart';
import 'signing.dart';
import 'spec.dart';

/// A summons as a juror receives it.
class Summons {
  const Summons({required this.spec, required this.hand, required this.jurors, required this.from});
  final TableSpec spec;
  final int hand;
  final List<PublicKey> jurors;
  final PublicKey from;

  static Summons? parse(PublicKey from, Map<String, Object?> content) {
    try {
      final spec = TableSpec.parse(content['table']);
      if (spec == null) return null;
      return Summons(
        spec: spec,
        hand: content['hand'] as int,
        jurors: [for (final k in content['jurors'] as List) k as String],
        from: from,
      );
    } catch (_) {
      return null;
    }
  }
}

class RelayPresence implements Presence {
  RelayPresence({required this.url, required this.signer, this.status = 'online', this.everyMs = 5000, this.log}) {
    _connect();
  }

  final Uri url;
  final Signer signer;

  /// What this client says of itself: `online`, or `last-resort` for
  /// the juror a service brings up.
  String status;
  final int everyMs;
  final void Function(String line)? log;

  static const topic = 'online';

  final Map<PublicKey, int> _seen = {};
  final _summonses = StreamController<Summons>.broadcast();
  final _calls = StreamController<String>.broadcast();
  final Set<String> _ids = {};
  WebSocketChannel? _channel;
  Timer? _beat;
  bool _closed = false;
  bool _silent = false;
  int _retryMs = 500;

  /// As on a table's socket (relay_transport.dart): a subscription that
  /// stops delivering without closing looks like an empty room, except
  /// that this client's own announcements come back on it. Nothing at
  /// all for [quietMs] after announcing means the socket is dead.
  static const quietMs = 25000;
  int _lastMessageMs = 0;
  int _lastPublishMs = 0;

  /// Summonses addressed to this key.
  Stream<Summons> get summonses => _summonses.stream;

  /// Tables that said they had nobody to draw from.
  Stream<String> get calls => _calls.stream;

  /// Stops announcing, while still listening — a juror of last resort
  /// stays quiet until called.
  set silent(bool v) => _silent = v;

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  Set<PublicKey> online({required int withinMs}) {
    final now = _nowMs;
    return {for (final e in _seen.entries) if (now - e.value < withinMs) e.key, if (!_silent) signer.publicKey};
  }

  @override
  void summon(PublicKey juror, Map<String, Object?> summons) {
    _publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'summons', ...summons}), tags: [
      ['t', topic],
      ['p', juror],
    ]));
  }

  @override
  void callForJuror(String table) {
    _publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'call', 'table': table}), tags: [
      ['t', topic],
    ]));
  }

  void _announce() {
    if (_silent) return;
    _publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'here', 'status': status}), tags: [
      ['t', topic],
    ]));
  }

  void _publish(NostrEvent e) {
    final ch = _channel;
    if (ch == null) return;
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
    log?.call('presence: nothing heard back for ${quietMs ~/ 1000} s; reconnecting');
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
      ch.sink.add(jsonEncode([
        'REQ',
        'online',
        const Filter(kinds: [TableKinds.presence]).toJson()..['#t'] = [topic],
      ]));
      _announce();
      _beat ??= Timer.periodic(Duration(milliseconds: everyMs), (_) {
        _announce();
        _checkLiveness();
      });
      log?.call('presence on $url');
    }).catchError((Object e) {
      log?.call('presence connect failed: $e');
    });
  }

  void _onDropped() {
    if (_closed) return;
    _channel = null;
    _lastMessageMs = _nowMs;
    log?.call('presence dropped; retrying in $_retryMs ms');
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
    if (m.length != 3 || m[0] != 'EVENT') return;
    final e = NostrEvent.parse(m[2]);
    if (e == null || e.kind != TableKinds.presence || e.tag('t') != topic) return;
    if (!_ids.add(e.id)) return;
    if (_ids.length > 20000) _ids.clear();
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    switch (c['kind']) {
      case 'here':
        _seen[e.pubkey] = _nowMs;
      case 'summons':
        if (e.tag('p') != signer.publicKey) return;
        final s = Summons.parse(e.pubkey, c);
        if (s != null) _summonses.add(s);
      case 'call':
        if (c['table'] is String) _calls.add(c['table'] as String);
    }
  }

  void close() {
    _closed = true;
    _beat?.cancel();
    _channel?.sink.close();
    _channel = null;
    _summonses.close();
    _calls.close();
  }
}
