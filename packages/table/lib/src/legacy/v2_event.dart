/// An event as tables played it before the referee (log.dart): what a
/// game kept then is made of, read by its record (v2_record.dart) and
/// by nothing else. Frozen as those builds signed it: an event's id
/// hashes its kind's name, so not one of the kinds changes, nor the
/// turns the record orders its decisions by.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../signing.dart';

enum V2Kind { pass, play, leave, boot, absent, witness, heartbeat, jury, serve, appeal, verdict, deal, release, topup, ended, escrow }

/// Which moment of a hand an event is about. A hand has four pass turns
/// (one per seat, all open at once) followed by fifty-two play turns.
/// At a sealed table (docs/explanation/fair-deal.md) they are preceded by the
/// deal's turns — four rounds of four, one per seat: keys, shuffle,
/// tokens, the lead declared — and followed by four audit turns.
class V2Turn {
  const V2Turn(this.hand, this.index);

  const V2Turn.pass(int hand, int seat) : this(hand, seat);
  const V2Turn.play(int hand, int play) : this(hand, passTurns + play);
  const V2Turn.deal(int hand, int round, int seat) : this(hand, dealBase + round * 4 + seat);
  const V2Turn.audit(int hand, int seat) : this(hand, passTurns + plays + seat);

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

  /// Where the turn sits in the hand, for ordering: the turns of a
  /// deal round share one position, as do the pass turns and the
  /// audit turns — each set is open at once and settles in a different
  /// order at every peer — while each play is its own.
  int get position => isDeal
      ? dealBase + dealRound * 4
      : isPass
          ? -1
          : isAudit
              ? passTurns + plays
              : index;

  @override
  bool operator ==(Object other) => other is V2Turn && other.hand == hand && other.index == index;
  @override
  int get hashCode => Object.hash(hand, index);
  @override
  String toString() => isDeal
      ? 'h$hand/deal$dealRound.$dealSeat'
      : isPass
          ? 'h$hand/pass'
          : isAudit
              ? 'h$hand/audit$auditSeat'
              : 'h$hand/t$playIndex';
}

class V2Event {
  V2Event._({
    required this.id,
    required this.table,
    required this.author,
    required this.kind,
    required this.body,
    required this.sig,
  });

  /// Builds, hashes and signs an event.
  factory V2Event.sign(Signer signer, {
    required String table,
    required V2Kind kind,
    required Map<String, Object?> body,
  }) {
    final canonical = _canonical(table, signer.publicKey, kind, body);
    final id = digestOf(canonical);
    return V2Event._(
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
  static V2Event? parse(Map<String, Object?> json, {bool verifySignature = true}) {
    try {
      final table = json['table'] as String;
      final author = json['author'] as String;
      final kind = V2Kind.values.byName(json['kind'] as String);
      final body = Map<String, Object?>.from(json['body'] as Map);
      final sig = json['sig'] as String;
      final id = digestOf(_canonical(table, author, kind, body));
      if (id != json['id']) return null;
      if (!wellFormed(kind, body)) return null;
      if (verifySignature && !verify(author, id, sig)) return null;
      return V2Event._(id: id, table: table, author: author, kind: kind, body: Map.unmodifiable(body), sig: sig);
    } on TypeError {
      // A field of the envelope missing or of the wrong type.
      return null;
    } on ArgumentError {
      // A kind this build does not know (V2Kind.values.byName).
      return null;
    }
  }

  /// Whether [body] has every field the typed views below read for
  /// [kind], each of its type, so that an event signed with a body
  /// that has not — by a peer of another build, or one that lies —
  /// is dropped here like any malformed event, and nothing past the
  /// parser meets a field that is missing. What a deal step, a pass or
  /// a release carries for the deal itself is the deal session's to
  /// check (DealSession), and is not looked at here.
  static bool wellFormed(V2Kind kind, Map<String, Object?> body) {
    bool ints(List<String> keys) => keys.every((k) => body[k] is int);
    bool text(String key) => body[key] is String;
    bool list<T>(String key) => body[key] is List && (body[key] as List).every((e) => e is T);
    final atTurn = ints(const ['hand', 'turn', 'seat']);
    return switch (kind) {
      V2Kind.pass => atTurn && (!body.containsKey('cards') || list<String>('cards')),
      V2Kind.play => atTurn && text('card'),
      V2Kind.leave || V2Kind.boot || V2Kind.absent || V2Kind.appeal || V2Kind.escrow => atTurn,
      V2Kind.witness => atTurn && text('event'),
      V2Kind.jury => atTurn && list<String>('jurors') && list<String>('snapshot'),
      V2Kind.verdict => atTurn && text('side') && body['event'] is Map,
      V2Kind.deal => atTurn && ints(const ['round']),
      V2Kind.ended => atTurn && body['vote'] is bool,
      V2Kind.heartbeat => ints(const ['hand', 'step']),
      V2Kind.serve => ints(const ['hand', 'step']) && list<int>('serving'),
      V2Kind.release => ints(const ['hand', 'about']),
      V2Kind.topup => ints(const ['hand', 'about', 'at']) && list<int>('have'),
    };
  }

  final String id;
  final String table;
  final PublicKey author;
  final V2Kind kind;
  final Map<String, Object?> body;
  final String sig;

  Map<String, Object?> toJson() =>
      {'id': id, 'table': table, 'author': author, 'kind': kind.name, 'body': body, 'sig': sig};

  /// The id an event with this content has, wherever it came from.
  /// A frame leaves the id out and this puts it back (`frame.dart`);
  /// the parser then checks it, as it checks one that travelled.
  static String idFor({required String table, required PublicKey author, required V2Kind kind, required Map<String, Object?> body}) =>
      digestOf(_canonical(table, author, kind, body));

  static Uint8List _canonical(String table, PublicKey author, V2Kind kind, Map<String, Object?> body) {
    final sortedBody = Map.fromEntries(body.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return Uint8List.fromList(utf8.encode(jsonEncode([table, author, kind.name, sortedBody])));
  }

  // ---- typed views of the body ----------------------------------------

  int get hand => body['hand'] as int;
  int get seat => body['seat'] as int;

  /// The turn a pass, play, boot or witness is about.
  V2Turn get turn => V2Turn(hand, body['turn'] as int);

  /// For leave and absent: the number of turns settled in [hand] when
  /// the event was made — "seat N is out as of game state S".
  int get step => body['step'] as int;

  /// For witness: the id of the event witnessed.
  String get witnessed => body['event'] as String;

  /// For jury: the jurors drawn, foreman first.
  List<PublicKey> get jurors => [for (final k in body['jurors'] as List) k as String];

  /// For jury: the keys online the draw was made from.
  List<PublicKey> get snapshot => [for (final k in body['snapshot'] as List) k as String];

  /// For verdict: which side of the race the juror ruled for.
  String get side => body['side'] as String;

  /// For deal: which round the step is — 0 keys, 1 shuffle, 2 tokens,
  /// 3 declare, 4 audit.
  int get round => body['round'] as int;

  /// For release: the seat whose secret the piece is of.
  int get about => body['about'] as int;

  /// For verdict: the event that wins — the seat's action, or the
  /// claim that removes it — carried whole, so a peer that never saw
  /// it can apply the verdict.
  V2Event? get ruled => body['event'] is Map ? V2Event.parse(Map<String, Object?>.from(body['event'] as Map)) : null;

  @override
  String toString() => '${kind.name}#${id.substring(0, 6)} by ${author.substring(0, 6)} $body';
}
