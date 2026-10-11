/// A NIP-01 relay, the subset the table needs.
///
/// Clients speak JSON arrays over a WebSocket: `["EVENT", event]` to
/// publish, `["REQ", id, filter…]` to subscribe, `["CLOSE", id]` to
/// stop. The relay answers `["OK", id, accepted, reason]`, streams
/// `["EVENT", sub, event]` for every match, marks the end of stored
/// history with `["EOSE", sub]`, and complains with `["NOTICE", text]`.
///
/// Every event is checked — id and signature — before anything else
/// sees it. Stored events are kept in memory, newest last, up to a cap;
/// ephemeral kinds (20000–29999) are forwarded and forgotten, which is
/// what every kind the table uses is. Locally the relay is this, one
/// `dart run`.
///
/// There are two of them (docs/06-service.md): this one, and the same
/// subset in JavaScript for the Cloudflare objects that carry presence
/// and the tables (`service/do/`). `OH_RELAY=js` puts that one behind this
/// class, so every suite here — the relay's own, a hand played over
/// real sockets, the jury, the waiting room — runs against whichever
/// relay is asked for, and the app's side of the wire is only written
/// once. `OH_RELAY=object` runs the JavaScript one under the deployed
/// object's own rules: a tag an address, and only that tag's kinds
/// ([JsRelay.object]).
///
///     cd service && dart test                     # this relay
///     cd service && OH_RELAY=js dart test         # the one the object runs
///     cd service && OH_RELAY=object dart test     # as the object runs it
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:table/table.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay_js.dart';

/// A relay a test or the local service can start and connect to,
/// whichever of the two is running underneath.
abstract class Relay {
  factory Relay({int keep = 10000, void Function(String line)? log, String? Function(NostrEvent event)? refuse}) =>
      switch (Platform.environment['OH_RELAY']) {
        'js' => JsRelay(keep: keep, log: log, refuse: refuse),
        'object' => JsRelay(keep: keep, log: log, refuse: refuse, object: true),
        _ => DartRelay(keep: keep, log: log, refuse: refuse),
      };

  /// A policy, for a test: the reason to refuse an event that checks
  /// out, or null to take it — what a relay does when it rate-limits a
  /// client or turns a kind away.
  set refuse(String? Function(NostrEvent event)? policy);

  /// The port the relay listens on once [serve] has returned.
  int get port;

  Uri get url;

  /// How many clients are connected, and how many events are stored.
  int get connections;
  int get stored;

  Future<void> serve({int port = 0});
  Future<void> close();
}

class DartRelay implements Relay {
  DartRelay({this.keep = 10000, this.log, this.refuse});

  /// How many stored events to hold before the oldest go.
  final int keep;

  /// Receives one line per connection, subscription and rejected event.
  final void Function(String line)? log;

  @override
  String? Function(NostrEvent event)? refuse;

  final List<NostrEvent> _stored = [];
  final Set<String> _seen = {};
  final Set<_Connection> _connections = {};
  HttpServer? _server;

  @override
  int get port => _server!.port;

  @override
  Uri get url => Uri(scheme: 'ws', host: 'localhost', port: port);

  @override
  int get connections => _connections.length;

  @override
  int get stored => _stored.length;

  /// Whether the socket compresses what it carries
  /// (`permessage-deflate`, RFC 7692). On: half of what a table sends
  /// is structure — JSON keys, hex ids, keys and signatures — and a
  /// deflate window kept between messages takes that half to a
  /// thirteenth of itself (docs/06-service.md). Off is for measuring
  /// what it is worth.
  ///
  /// The upgrade is dart:io's own rather than a package's, because
  /// this is the one place the extension is agreed to or not: the
  /// clients already offer it.
  bool compress = true;

  /// What the relay has sent, by NIP-01 message kind, in the bytes of
  /// the JSON before framing: EVENT, OK, EOSE, NOTICE. A measurement
  /// reads it to tell a hand's own traffic from its fan-out.
  final Map<String, int> sent = {};

  /// And what it has been sent, the same way.
  final Map<String, int> received = {};

  /// Who published what, by the table's own kind, and whether the
  /// envelope's signer is the one who said the thing inside it — a
  /// table says again what has not settled, and a saying-again
  /// carries somebody else's event. Off by default: it opens every
  /// event's content to do it, which is a measurement's price to pay
  /// and not a relay's (tool/wire_over_socket.dart).
  bool tally = false;
  final Map<String, int> byAuthor = {};

  @override
  Future<void> serve({int port = 0, Object? address}) async {
    final server = _server = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('a relay speaks websocket')
          ..close();
        return;
      }
      // What the client offered, since what was agreed cannot be read
      // back: dart:io's WebSocket.extensions is the empty string on
      // both sides whatever happens. Bytes on the wire are the only
      // honest check (tool/wire_over_socket.dart).
      _log('upgrade offers ${request.headers['sec-websocket-extensions']}');
      try {
        final ws = await WebSocketTransformer.upgrade(request,
            compression: compress ? CompressionOptions.compressionDefault : CompressionOptions.compressionOff);
        _accept(IOWebSocketChannel(ws));
      } catch (e) {
        _log('upgrade refused: $e');
      }
    });
    _log('relay on $url');
  }

  @override
  Future<void> close() async {
    for (final c in List.of(_connections)) {
      await c.channel.sink.close();
    }
    await _server?.close(force: true);
    _server = null;
  }

  void _log(String line) => log?.call(line);

  void _accept(WebSocketChannel channel) {
    final c = _Connection(channel, sent);
    _connections.add(c);
    _log('connected (${_connections.length})');
    channel.stream.listen(
      (raw) => _onMessage(c, raw),
      onDone: () {
        _connections.remove(c);
        _log('closed (${_connections.length})');
      },
      onError: (_) => _connections.remove(c),
    );
  }

  void _onMessage(_Connection c, Object? raw) {
    Object? json;
    try {
      json = jsonDecode(raw as String);
    } catch (_) {
      return c.send(['NOTICE', 'not JSON']);
    }
    if (json is! List || json.isEmpty || json.first is! String) return c.send(['NOTICE', 'not a message']);
    final kind = json.first as String;
    received[kind] = (received[kind] ?? 0) + raw.length;
    if (tally && kind == 'EVENT' && json.length > 1 && json[1] is Map) {
      final e = json[1] as Map;
      final who = '${e['pubkey']}'.substring(0, 4);
      var k = '${e['kind']}';
      // The table's own kind, where there is one: what a relay carries
      // is a nostr event whose content is the table's.
      var mine = '';
      try {
        final inner = jsonDecode('${e['content']}');
        if (inner is Map && inner['kind'] is String) {
          k = '${inner['kind']}';
          // Whether the envelope's signer is the one who said the
          // thing inside it: a table re-says what has not settled, and
          // a re-saying carries somebody else's event.
          mine = inner['author'] == e['pubkey'] ? ' own' : ' resaid';
        }
      } catch (_) {}
      byAuthor['$who/$k$mine'] = (byAuthor['$who/$k$mine'] ?? 0) + raw.length;
    }
    switch (kind) {
      case 'EVENT':
        if (json.length != 2) return c.send(['NOTICE', 'EVENT takes one event']);
        _publish(c, json[1]);
      case 'REQ':
        if (json.length < 3 || json[1] is! String) return c.send(['NOTICE', 'REQ takes an id and filters']);
        final id = json[1] as String;
        final filters = <Filter>[];
        for (final f in json.sublist(2)) {
          final parsed = Filter.parse(f);
          if (parsed == null) return c.send(['NOTICE', 'bad filter']);
          filters.add(parsed);
        }
        c.subscriptions[id] = filters;
        _log('sub $id: ${filters.map((f) => jsonEncode(f.toJson())).join(' ')}');
        // Stored history first, oldest first, honouring limit from the
        // newest end; then the end-of-stored-events mark.
        var matches = _stored.where((e) => filters.any((f) => f.matches(e))).toList();
        final limit = filters.map((f) => f.limit).whereType<int>().fold<int?>(null, (a, b) => a == null ? b : (a > b ? a : b));
        if (limit != null && matches.length > limit) matches = matches.sublist(matches.length - limit);
        for (final e in matches) {
          c.send(['EVENT', id, e.toJson()]);
        }
        c.send(['EOSE', id]);
      case 'CLOSE':
        if (json.length == 2 && json[1] is String) c.subscriptions.remove(json[1] as String);
      default:
        c.send(['NOTICE', 'unknown message ${json.first}']);
    }
  }

  void _publish(_Connection from, Object? json) {
    final event = NostrEvent.parse(json);
    if (event == null) {
      final id = json is Map ? json['id'] : null;
      _log('rejected ${id is String ? id.substring(0, 6) : '?'}');
      return from.send(['OK', id is String ? id : '', false, 'invalid: bad id or signature']);
    }
    final why = refuse?.call(event);
    if (why != null) {
      _log('refused ${event.id.substring(0, 6)}: $why');
      return from.send(['OK', event.id, false, why]);
    }
    if (!_seen.add(event.id)) return from.send(['OK', event.id, true, 'duplicate: already have this event']);
    if (!event.ephemeral) {
      _stored.add(event);
      if (_stored.length > keep) {
        final gone = _stored.removeAt(0);
        _seen.remove(gone.id);
      }
    } else if (_seen.length > 4 * keep) {
      // Ephemeral ids are remembered only to answer duplicates; do not
      // let them grow without bound.
      _seen.clear();
      _seen.addAll(_stored.map((e) => e.id));
    }
    from.send(['OK', event.id, true, '']);
    final wire = event.toJson();
    for (final c in _connections) {
      for (final s in c.subscriptions.entries) {
        if (s.value.any((f) => f.matches(event))) {
          c.send(['EVENT', s.key, wire]);
          break;
        }
      }
    }
  }
}

class _Connection {
  _Connection(this.channel, this.tally);
  final WebSocketChannel channel;
  final Map<String, int> tally;
  final Map<String, List<Filter>> subscriptions = {};

  void send(List<Object?> message) {
    final json = jsonEncode(message);
    // What the relay sends, by the kind of message it is, so a
    // measurement can say whether a hand's wire is the hand or the
    // fan-out (tool/wire_over_socket.dart).
    final kind = message.isEmpty ? '?' : '${message.first}';
    tally[kind] = (tally[kind] ?? 0) + json.length;
    try {
      channel.sink.add(json);
    } catch (_) {
      // A closing socket; the done handler will drop the connection.
    }
  }
}
