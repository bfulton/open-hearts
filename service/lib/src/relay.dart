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
/// what every kind the table uses is. In production this is a public
/// relay somebody else runs; locally it is this, one `dart run`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:table/table.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class Relay {
  Relay({this.keep = 10000, this.log});

  /// How many stored events to hold before the oldest go.
  final int keep;

  /// Receives one line per connection, subscription and rejected event.
  final void Function(String line)? log;

  final List<NostrEvent> _stored = [];
  final Set<String> _seen = {};
  final Set<_Connection> _connections = {};
  HttpServer? _server;

  /// The port the relay listens on once [serve] has returned.
  int get port => _server!.port;

  Uri get url => Uri(scheme: 'ws', host: 'localhost', port: port);

  int get connections => _connections.length;
  int get stored => _stored.length;

  Future<void> serve({int port = 0, Object? address}) async {
    final handler = webSocketHandler((WebSocketChannel channel, String? protocol) => _accept(channel));
    _server = await shelf_io.serve(handler, address ?? InternetAddress.loopbackIPv4, port);
    _log('relay on $url');
  }

  Future<void> close() async {
    for (final c in List.of(_connections)) {
      await c.channel.sink.close();
    }
    await _server?.close(force: true);
    _server = null;
  }

  void _log(String line) => log?.call(line);

  void _accept(WebSocketChannel channel) {
    final c = _Connection(channel);
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
    switch (json.first as String) {
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
  _Connection(this.channel);
  final WebSocketChannel channel;
  final Map<String, List<Filter>> subscriptions = {};

  void send(List<Object?> message) {
    try {
      channel.sink.add(jsonEncode(message));
    } catch (_) {
      // A closing socket; the done handler will drop the connection.
    }
  }
}
