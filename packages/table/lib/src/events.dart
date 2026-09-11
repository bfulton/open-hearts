/// What travels between seats.
///
/// Every event is signed by its author and identified by the hash of
/// its canonical bytes, so it can be relayed by anyone, deduplicated by
/// anyone, and never forged. The kinds are few: the two things a seat
/// does at the table (pass, play), the three doors out (leave, and the
/// two inferred ones, boot and absent), a witness signature over any of
/// those, and a heartbeat.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';

enum EventKind { pass, play, leave, boot, absent, witness, heartbeat }

/// Which moment of a hand an event is about. A hand has four pass turns
/// (one per seat, all open at once) followed by fifty-two play turns.
class TurnId {
  const TurnId(this.hand, this.index);

  const TurnId.pass(int hand, int seat) : this(hand, seat);
  const TurnId.play(int hand, int play) : this(hand, passTurns + play);

  final int hand;
  final int index;

  static const passTurns = 4;

  bool get isPass => index < passTurns;
  int get playIndex => index - passTurns;

  @override
  bool operator ==(Object other) => other is TurnId && other.hand == hand && other.index == index;
  @override
  int get hashCode => Object.hash(hand, index);
  @override
  String toString() => isPass ? 'h$hand/pass' : 'h$hand/t$playIndex';
}

class TableEvent {
  TableEvent._({
    required this.id,
    required this.table,
    required this.author,
    required this.kind,
    required this.body,
    required this.sig,
  });

  /// Builds, hashes and signs an event.
  factory TableEvent.sign(Signer signer, {
    required String table,
    required EventKind kind,
    required Map<String, Object?> body,
  }) {
    final canonical = _canonical(table, signer.publicKey, kind, body);
    final id = digestOf(canonical);
    return TableEvent._(
      id: id,
      table: table,
      author: signer.publicKey,
      kind: kind,
      body: Map.unmodifiable(body),
      sig: signer.sign(id),
    );
  }

  /// Parses a received event and checks its hash and signature. Returns
  /// null for anything malformed or unsigned by its claimed author.
  static TableEvent? parse(Map<String, Object?> json) {
    try {
      final table = json['table'] as String;
      final author = json['author'] as String;
      final kind = EventKind.values.byName(json['kind'] as String);
      final body = Map<String, Object?>.from(json['body'] as Map);
      final sig = json['sig'] as String;
      final id = digestOf(_canonical(table, author, kind, body));
      if (id != json['id']) return null;
      if (!verify(author, id, sig)) return null;
      return TableEvent._(id: id, table: table, author: author, kind: kind, body: Map.unmodifiable(body), sig: sig);
    } catch (_) {
      return null;
    }
  }

  final String id;
  final String table;
  final PublicKey author;
  final EventKind kind;
  final Map<String, Object?> body;
  final String sig;

  Map<String, Object?> toJson() =>
      {'id': id, 'table': table, 'author': author, 'kind': kind.name, 'body': body, 'sig': sig};

  static Uint8List _canonical(String table, PublicKey author, EventKind kind, Map<String, Object?> body) {
    final sortedBody = Map.fromEntries(body.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return Uint8List.fromList(utf8.encode(jsonEncode([table, author, kind.name, sortedBody])));
  }

  // ---- typed views of the body ----------------------------------------

  int get hand => body['hand'] as int;
  int get seat => body['seat'] as int;

  /// The turn a pass, play, boot or witness is about.
  TurnId get turn => TurnId(hand, body['turn'] as int);

  /// For leave and absent: the number of turns settled in [hand] when
  /// the event was made — "seat N is out as of game state S".
  int get step => body['step'] as int;

  /// For witness: the id of the event witnessed.
  String get witnessed => body['event'] as String;

  @override
  String toString() => '${kind.name}#${id.substring(0, 6)} by ${author.substring(0, 6)} $body';
}
