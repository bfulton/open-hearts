/// A table's log: everything that happened at it, in the one order the
/// referee gave it (docs/explanation/live-play.md).
///
/// The referee is the table's object on our relay. It numbers what it
/// is sent, stamps each entry with its own clock, and notes when a
/// seat's connection opens and closes; it sees no cards and decides
/// nothing. Every side applies the same rules to the same entries
/// (rules.dart), so every side, and anyone checking the game later,
/// comes to the same table.
library;

import 'dart:convert';

import 'events.dart';
import 'signing.dart';

/// One entry: an event, a connection opened or closed, or a tick — the
/// time, asked for by a side waiting on a deadline.
class LogEntry {
  const LogEntry({required this.n, required this.t, this.event, this.unread, this.up, this.down});

  /// Where the entry is in the log, from zero.
  final int n;

  /// The referee's clock, in milliseconds since the epoch.
  final int t;

  /// A signed event from a seat or the house.
  final TableEvent? event;

  /// An event the referee took, signed by a key it takes from, that does
  /// not read here: one of another shape, or whose id is not its bytes'.
  /// The referee checks the signature on the id and no more — it cannot
  /// make a Dart side's canonical bytes — so a person can put one in the
  /// log. It is kept as it came and changes nothing, at every side alike;
  /// the hash takes its id as it takes any event's.
  final Map<String, Object?>? unread;

  /// A key whose first connection to the log opened.
  final PublicKey? up;

  /// A key whose last connection to the log closed.
  final PublicKey? down;

  bool get isTick => event == null && unread == null && up == null && down == null;

  Map<String, Object?> toJson() => {
        'n': n,
        't': t,
        if (event != null) 'e': event!.toJson(),
        if (unread != null) 'e': unread,
        if (up != null) 'up': up,
        if (down != null) 'down': down,
      };

  /// As the referee sends it, or null for anything else. An event that
  /// does not read is [unread], so long as it names its id: the referee
  /// takes none that does not.
  static LogEntry? parse(Object? json, {bool verifySignature = true}) {
    try {
      final m = json as Map;
      final n = m['n'] as int;
      final t = m['t'] as int;
      final e = m['e'];
      final raw = e == null ? null : Map<String, Object?>.from(e as Map);
      final event = raw == null ? null : TableEvent.parse(raw, verifySignature: verifySignature);
      final unread = raw != null && event == null ? raw : null;
      if (unread != null && !_isId(unread['id'])) return null;
      final up = m['up'] as String?;
      final down = m['down'] as String?;
      if ([raw, up, down].where((x) => x != null).length > 1) return null;
      return LogEntry(n: n, t: t, event: event, unread: unread, up: up, down: down);
    } catch (_) {
      return null;
    }
  }

  static bool _isId(Object? id) => id is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(id);

  /// What the entry adds to the log's running hash ([LogHash]).
  String get digestInput => switch (this) {
        LogEntry(:final event?) => '$n|$t|e|${event.id}',
        LogEntry(:final unread?) => '$n|$t|e|${unread['id']}',
        LogEntry(:final up?) => '$n|$t|up|$up',
        LogEntry(:final down?) => '$n|$t|down|$down',
        _ => '$n|$t|tick',
      };

  @override
  String toString() => switch (this) {
        LogEntry(:final event?) => '#$n @$t $event',
        LogEntry(:final unread?) => '#$n @$t unread ${'${unread['id']}'.substring(0, 6)}',
        LogEntry(:final up?) => '#$n @$t up ${up.substring(0, 6)}',
        LogEntry(:final down?) => '#$n @$t down ${down.substring(0, 6)}',
        _ => '#$n @$t tick',
      };
}

/// The log's running hash: each entry folded into the one before. The
/// house signs it with the game's result (EventKind.result), so a log
/// kept afterwards is the one the referee gave, entry for entry, or it
/// does not check.
class LogHash {
  String _at = sha256Hex(utf8.encode('open-hearts/log/1'));
  int _count = 0;

  /// The hash after the entries folded in so far.
  String get value => _at;

  /// How many entries are folded in.
  int get count => _count;

  void add(LogEntry e) {
    if (e.n != _count) throw StateError('entry ${e.n} folded in at $_count');
    _at = sha256Hex(utf8.encode('$_at|${e.digestInput}'));
    _count++;
  }
}
