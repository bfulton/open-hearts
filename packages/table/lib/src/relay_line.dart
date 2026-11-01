/// A side's line to the table's referee over our relay
/// (referee_line.dart): one socket to the table's object.
///
/// On every socket the line asks for the log from the first entry it has
/// not had (`LOG`), takes entries in order, and when one comes that is
/// not the next it asks again from there. What it sends goes as an
/// `EVENT` of [TableKinds.log], and is said again on every new socket
/// until an entry carrying it comes back. A tick is `TICK`.
library;

import 'dart:convert';

import 'events.dart';
import 'log.dart';
import 'nostr.dart';
import 'referee_line.dart';
import 'relays.dart';
import 'signing.dart';

class RelayLine implements RefereeLine {
  RelayLine({required List<Uri> relays, required this.signer, required this.table, this.log, this.cutOffMs = unansweredMs})
      : url = tableUrl(relays, table);

  /// How long a silence with something unanswered takes the line for
  /// cut off ([RelayConnection.cutOff]): [unansweredMs], shorter in a
  /// test.
  final int cutOffMs;

  /// The table's object: the first of the relays the build names, with
  /// the table's id where it asks for a tag.
  final Uri url;

  final Signer signer;
  final String table;
  final void Function(String line)? log;

  RelayConnection? _connection;
  void Function(LogEntry entry)? _onEntry;
  int _next = 0;
  bool _caughtUp = false;
  bool _closed = false;
  String? _refused;
  void Function(bool up)? _onUp;

  /// What this side has sent that the log has not yet carried back, by
  /// event id, in the order it was sent.
  final Map<String, NostrEvent> _pending = {};

  static const _sub = 'log';

  @override
  void open(int from, void Function(LogEntry entry) onEntry) {
    _next = from;
    _onEntry = onEntry;
    _connection = RelayConnection(
      url: url,
      subscriptions: const {},
      onMessage: _onMessage,
      log: log,
      auth: relayAuthFor(signer),
      onOpen: _opened,
      // Quiet a while: the log again from where this side is, which the
      // referee answers with whatever came since and its end. The answer
      // is what tells a line still carrying from one stalled.
      onIdle: (c) => c.sendRaw(['LOG', _sub, _next]),
      cutOffMs: cutOffMs,
      answerWaitMs: answerMs.clamp(0, cutOffMs ~/ 3),
    )..onDropped = (_) => _setUp(false);
  }

  void _opened(RelayConnection c) {
    _caughtUp = false;
    c.sendRaw(['LOG', _sub, _next]);
    for (final e in _pending.values) {
      c.sendRaw(['EVENT', e.toJson()]);
    }
  }

  void _onMessage(RelayConnection from, List<Object?> m) {
    switch (m[0]) {
      case 'LOG':
        if (m.length != 3 || m[1] != _sub) return;
        final raw = m[2];
        final n = raw is Map ? raw['n'] : null;
        if (n is! int) return;
        if (n < _next) return; // had it
        if (n > _next) {
          // A gap: the socket missed something. Asked again from where
          // this side is.
          log?.call('log: entry $n came where $_next was due; asking again');
          from.sendRaw(['LOG', _sub, _next]);
          return;
        }
        final entry = LogEntry.parse(raw);
        if (entry == null) {
          log?.call('log: entry $n does not read; the table cannot go on from here');
          return;
        }
        _next++;
        final id = entry.event?.id;
        if (id != null) _pending.removeWhere((_, e) => _innerId(e) == id);
        _onEntry?.call(entry);
      case 'LOGEND':
        if (m.length == 3 && m[1] == _sub) {
          _caughtUp = true;
          _setUp(true);
        }
      case 'OK':
        if (m.length < 4) return;
        final why = '${m[3]}';
        // What the referee will never take, or has already: a start
        // after the table's, an event the log has, one it does not take
        // from this key. Not said again on the next socket.
        if (_settled(why)) _pending.remove(m[1]);
        if (m[2] == false) {
          if (turnedAway(why)) {
            _refused = why;
            _setUp(false);
          }
          log?.call('log: not taken: $why');
        }
      case 'NOTICE':
        log?.call('log: ${m.length > 1 ? m[1] : ''}');
    }
  }

  /// Whether the referee's answer [why] is its last word on an event:
  /// in the log already, or never to be.
  static bool _settled(String why) => why.startsWith('duplicate:') || why.startsWith('blocked:') || why.startsWith('invalid:');

  /// What this side has sent that the log has not carried back and the
  /// referee has not refused for good.
  int get unsaid => _pending.length;

  static String? _innerId(NostrEvent e) {
    try {
      return (jsonDecode(e.content) as Map)['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  void send(TableEvent event) {
    if (_closed) return;
    final e = NostrEvent.sign(signer, kind: TableKinds.log, content: jsonEncode(event.toJson()), tags: [
      ['t', table],
    ]);
    _pending[e.id] = e;
    _connection?.sendRaw(['EVENT', e.toJson()]);
  }

  @override
  void tick() => _connection?.sendRaw(['TICK']);

  bool _up = false;

  @override
  bool get up => _up && !_closed;

  void _setUp(bool v) {
    final now = v && _caughtUp && _refused == null;
    if (now == _up) return;
    _up = now;
    _onUp?.call(now);
  }

  @override
  set onUp(void Function(bool up)? f) => _onUp = f;

  @override
  String? get refused => _refused;

  /// The line in a few words, for an account of a game lost to it.
  String get health {
    final c = _connection;
    if (c == null) return 'not open';
    final heard = c.heardAgoMs;
    return '${c.connected ? 'open' : 'down'}; ${heard == null ? 'never heard' : 'heard $heard ms ago'}; '
        'dropped ${c.drops}, for silence ${c.silences}; at entry $_next, ${_pending.length} unsaid';
  }

  @override
  void close() {
    _closed = true;
    _connection?.close();
  }

  /// The table's object among [relays]: the first, its tag put in.
  static Uri tableUrl(List<Uri> relays, String table) => relaysForTag(relays, table).first;
}
