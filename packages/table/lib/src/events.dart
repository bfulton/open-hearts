/// What a table's log holds, besides the referee's own entries (log.dart).
///
/// Every event is signed by its author and identified by the hash of
/// its canonical bytes, so nobody can forge one and the referee can only
/// order it. The kinds are few: the start, which carries the spec; the
/// sealed deal's steps (docs/explanation/fair-deal.md) — keys, a
/// shuffle, tokens, the lead declared, the audit; a seat's pass and
/// play; a person's leave; a piece of a departed person's secret,
/// released; and the house's word on how the game came out.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';

/// The kinds, by name: an event's id hashes its kind's name, so a name
/// never changes once a table has used it.
enum EventKind { start, deal, pass, play, leave, release, result }

/// Which moment of a hand an event is about. A hand has four pass turns
/// (one per seat, all open at once) followed by fifty-two play turns.
/// At a sealed table (docs/explanation/fair-deal.md) they are preceded by the
/// deal's turns — four rounds of four, one per seat: keys, shuffle,
/// tokens, the lead declared — and followed by four audit turns.
class TurnId {
  const TurnId(this.hand, this.index);

  const TurnId.pass(int hand, int seat) : this(hand, seat);
  const TurnId.play(int hand, int play) : this(hand, passTurns + play);
  const TurnId.deal(int hand, int round, int seat) : this(hand, dealBase + round * 4 + seat);
  const TurnId.audit(int hand, int seat) : this(hand, passTurns + plays + seat);

  final int hand;
  final int index;

  static const passTurns = 4;
  static const plays = 52;

  /// The deal's rounds: keys, shuffle, tokens, declare.
  static const dealRounds = 4;

  /// Deal turns sit below zero, so a seeded table's turns, which have
  /// no deal, still count from zero.
  static const dealBase = -(dealRounds * 4);

  bool get isDeal => index < 0;
  bool get isPass => index >= 0 && index < passTurns;
  bool get isPlay => index >= passTurns && index < passTurns + plays;
  bool get isAudit => index >= passTurns + plays;
  int get playIndex => index - passTurns;
  int get dealRound => (index - dealBase) ~/ 4;
  int get dealSeat => (index - dealBase) % 4;
  int get auditSeat => index - passTurns - plays;

  @override
  bool operator ==(Object other) => other is TurnId && other.hand == hand && other.index == index;
  @override
  int get hashCode => Object.hash(hand, index);
  @override
  String toString() => isDeal
      ? 'h$hand/deal$dealRound.$dealSeat'
      : isPass
          ? 'h$hand/pass$index'
          : isAudit
              ? 'h$hand/audit$auditSeat'
              : 'h$hand/t$playIndex';
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
  /// With [verifySignature] off only the hash is checked — for an
  /// event already seen, whose signature was checked the first time:
  /// the same id is the same bytes.
  static TableEvent? parse(Map<String, Object?> json, {bool verifySignature = true}) {
    try {
      final table = json['table'] as String;
      final author = json['author'] as String;
      final kind = EventKind.values.byName(json['kind'] as String);
      final body = Map<String, Object?>.from(json['body'] as Map);
      final sig = json['sig'] as String;
      final id = digestOf(_canonical(table, author, kind, body));
      if (id != json['id']) return null;
      if (!wellFormed(kind, body)) return null;
      if (verifySignature && !verify(author, id, sig)) return null;
      return TableEvent._(id: id, table: table, author: author, kind: kind, body: Map.unmodifiable(body), sig: sig);
    } on TypeError {
      // A field of the envelope missing or of the wrong type.
      return null;
    } on ArgumentError {
      // A kind this build does not know (EventKind.values.byName).
      return null;
    }
  }

  /// Whether [body] has every field the typed views below read for
  /// [kind], each of its type, so that an event signed with a body
  /// that has not is dropped here like any malformed event, and
  /// nothing past the parser meets a field that is missing. What a
  /// deal step, a pass or a release carries for the deal itself is the
  /// deal session's to check (DealSession), and is not looked at here.
  static bool wellFormed(EventKind kind, Map<String, Object?> body) {
    bool ints(List<String> keys) => keys.every((k) => body[k] is int);
    bool text(String key) => body[key] is String;
    bool list<T>(String key) => body[key] is List && (body[key] as List).every((e) => e is T);
    final atTurn = ints(const ['hand', 'turn', 'seat']);
    return switch (kind) {
      EventKind.start => body['spec'] is Map,
      EventKind.deal => atTurn && ints(const ['round']),
      EventKind.pass => atTurn && (!body.containsKey('cards') || list<String>('cards')),
      EventKind.play => atTurn && text('card'),
      EventKind.leave => ints(const ['seat']),
      EventKind.release => ints(const ['hand', 'about']),
      EventKind.result => ints(const ['n']) && text('hash') && text('state') && list<int>('totals'),
    };
  }

  final String id;
  final String table;
  final PublicKey author;
  final EventKind kind;
  final Map<String, Object?> body;
  final String sig;

  Map<String, Object?> toJson() =>
      {'id': id, 'table': table, 'author': author, 'kind': kind.name, 'body': body, 'sig': sig};

  /// The bytes an event's id is the hash of: its table, author, kind and
  /// body as JSON, with every map's keys in order at every depth. Nothing
  /// that carries an event keeps a map's keys in the order they were
  /// written: the relay's referee is JavaScript, whose objects put a key
  /// like "2" ahead of "3" whatever order they came in, and it writes
  /// every event it takes out again from the object it parsed. So that
  /// order cannot move the id (functions/records.mjs, eventIdOf, makes the
  /// same bytes).
  static Uint8List _canonical(String table, PublicKey author, EventKind kind, Map<String, Object?> body) =>
      Uint8List.fromList(utf8.encode(jsonEncode([table, author, kind.name, _inOrder(body)])));

  static Object? _inOrder(Object? json) {
    if (json is List) return [for (final e in json) _inOrder(e)];
    if (json is! Map) return json;
    final keys = [for (final k in json.keys) k as String]..sort();
    return {for (final k in keys) k: _inOrder(json[k])};
  }

  // ---- typed views of the body ----------------------------------------

  int get hand => body['hand'] as int;
  int get seat => body['seat'] as int;

  /// The turn a deal step, a pass or a play is for.
  TurnId get turn => TurnId(hand, body['turn'] as int);

  /// For deal: which round the step is — 0 keys, 1 shuffle, 2 tokens,
  /// 3 declare, 4 audit.
  int get round => body['round'] as int;

  /// For release: the seat whose secret the piece is of.
  int get about => body['about'] as int;

  @override
  String toString() => '${kind.name}#${id.substring(0, 6)} by ${author.substring(0, 6)}';
}
