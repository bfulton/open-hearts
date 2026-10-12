/// What travels between seats.
///
/// Every event is signed by its author and identified by the hash of
/// its canonical bytes, so it can be relayed by anyone, deduplicated by
/// anyone, and never forged. The kinds are few: the two things a seat
/// does at the table (pass, play), the three doors out (leave, and the
/// two inferred ones, boot and absent), a witness signature over any of
/// those, and a heartbeat; the jury's four (jury.dart): a proposal
/// of who the hand's jurors are, a juror's heartbeat while it serves,
/// an appeal of a turn the players cannot settle, and a verdict; and
/// the sealed deal's three (docs/explanation/fair-deal.md): a step of the deal —
/// keys, a shuffle, tokens, the lead declared, the audit — the release
/// of a piece of a departed seat's secret, and a part of a new piece
/// for a juror brought on mid-hand. A claim that a held bot seat's
/// juror is out at the seat's turn, which gives the seat to the escrow
/// once it carries, as a boot removes a person. And one more, outside
/// the record: a person's word that the game has ended for them,
/// stopped where nobody left could move it (client.dart).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';

/// Appended to, never reordered: a frame carries a kind as its place
/// in this list (frame.dart).
enum EventKind { pass, play, leave, boot, absent, witness, heartbeat, jury, serve, appeal, verdict, deal, release, topup, ended, escrow }

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
  bool operator ==(Object other) => other is TurnId && other.hand == hand && other.index == index;
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
  /// that has not — by a peer of another build, or one that lies —
  /// is dropped here like any malformed event, and nothing past the
  /// parser meets a field that is missing. What a deal step, a pass or
  /// a release carries for the deal itself is the deal session's to
  /// check (DealSession), and is not looked at here.
  static bool wellFormed(EventKind kind, Map<String, Object?> body) {
    bool ints(List<String> keys) => keys.every((k) => body[k] is int);
    bool text(String key) => body[key] is String;
    bool list<T>(String key) => body[key] is List && (body[key] as List).every((e) => e is T);
    final atTurn = ints(const ['hand', 'turn', 'seat']);
    return switch (kind) {
      EventKind.pass => atTurn && (!body.containsKey('cards') || list<String>('cards')),
      EventKind.play => atTurn && text('card'),
      EventKind.leave || EventKind.boot || EventKind.absent || EventKind.appeal || EventKind.escrow => atTurn,
      EventKind.witness => atTurn && text('event'),
      EventKind.jury => atTurn && list<String>('jurors') && list<String>('snapshot'),
      EventKind.verdict => atTurn && text('side') && body['event'] is Map,
      EventKind.deal => atTurn && ints(const ['round']),
      EventKind.ended => atTurn && body['vote'] is bool,
      EventKind.heartbeat => ints(const ['hand', 'step']),
      EventKind.serve => ints(const ['hand', 'step']) && list<int>('serving'),
      EventKind.release => ints(const ['hand', 'about']),
      EventKind.topup => ints(const ['hand', 'about', 'at']) && list<int>('have'),
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

  /// The id an event with this content has, wherever it came from.
  /// A frame leaves the id out and this puts it back (`frame.dart`);
  /// the parser then checks it, as it checks one that travelled.
  static String idFor({required String table, required PublicKey author, required EventKind kind, required Map<String, Object?> body}) =>
      digestOf(_canonical(table, author, kind, body));

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
  TableEvent? get ruled => body['event'] is Map ? TableEvent.parse(Map<String, Object?>.from(body['event'] as Map)) : null;

  @override
  String toString() => '${kind.name}#${id.substring(0, 6)} by ${author.substring(0, 6)} $body';
}
