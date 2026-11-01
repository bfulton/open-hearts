/// A game as it was kept before the referee (log.dart): the table, every
/// decision with the signed events behind it, the juries that carried,
/// and the escrow pieces released for seats that left — the record's
/// first two versions — and the verifier those builds checked it by.
///
/// Frozen. Games kept then are kept for good, and anyone looking at one
/// checks it here exactly as it was checked when it was played: every
/// event's signature, every removal's majority, every jury's draw and
/// every verdict, and at a sealed table every step of the deal. A game
/// played since is the referee's log and its own record (record.dart).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import '../names.dart';
import '../replay.dart';
import '../sealed_pass.dart';
import '../signing.dart';
import '../spec.dart';
import 'v2_event.dart';
import 'v2_jury.dart';

class GameRecordV2 {
  const GameRecordV2({required this.spec, required this.record, this.juries = const [], this.releases = const [], this.names = const {}});

  final TableSpec spec;
  final List<Decision> record;
  final List<Decision> juries;
  final List<V2Event> releases;

  /// What each person was called at the table, by seat. Not signed: a
  /// name is what a device said it was called, and shown as that. The
  /// moves are what the record vouches for.
  final Map<int, String> names;

  /// The record's form. Version 2 carries with each removal the signed
  /// word of everyone who backed it ([Decision.backing]); version 1,
  /// kept before, names them by key alone, and is read as it was.
  static const version = 2;

  Map<String, Object?> toJson() => {
        'v': version,
        'spec': spec.toJson(),
        'record': [for (final d in record) _decision(d)],
        if (juries.isNotEmpty) 'juries': [for (final d in juries) _decision(d)],
        if (releases.isNotEmpty) 'releases': [for (final e in releases) e.toJson()],
        if (names.isNotEmpty) 'names': {for (final e in names.entries) '${e.key}': e.value},
      };

  static Map<String, Object?> _decision(Decision d) => {
        'turn': [d.turn.hand, d.turn.index],
        'event': d.event.toJson(),
        'witnesses': d.witnesses.toList()..sort(),
        if (d.removal) 'removal': true,
        if (d.among.isNotEmpty) 'among': d.among.toList()..sort(),
        if (d.jury) 'jury': true,
        if (d.verdict case final v?) 'verdict': v.toJson(),
        if (d.removal) 'backing': [for (final e in d.backing ?? const <V2Event>[]) e.toJson()],
      };

  /// Null for anything that is not a record, or carries an event whose
  /// signature does not check. Whether the record is a legal game is
  /// the verifier's to say, not this.
  static GameRecordV2? parse(Object? json, {bool verifySignatures = true}) {
    try {
      final m = json as Map;
      final v = m['v'];
      if (v != 1 && v != version) return null;
      final spec = TableSpec.parse(m['spec'], legacy: true);
      if (spec == null) return null;
      V2Event event(Object? e) =>
          V2Event.parse(Map<String, Object?>.from(e as Map), verifySignature: verifySignatures) ?? (throw const FormatException('event'));
      V2Event ours(Object? e) {
        final made = event(e);
        if (made.table != spec.id) throw const FormatException('another table\'s event');
        return made;
      }

      Decision decision(Object? raw) {
        final d = raw as Map;
        final turn = d['turn'] as List;
        return Decision(
          turn: V2Turn(turn[0] as int, turn[1] as int),
          event: ours(d['event']),
          witnesses: {for (final k in d['witnesses'] as List) k as String},
          removal: d['removal'] == true,
          among: {for (final k in (d['among'] as List?) ?? const []) k as String},
          jury: d['jury'] == true,
          verdict: d['verdict'] == null ? null : event(d['verdict']),
          // Kept before removals carried their backing: the keys are
          // all there is ([Decision.backing]).
          backing: v == 1 ? null : [for (final e in (d['backing'] as List?) ?? const []) ours(e)],
        );
      }

      return GameRecordV2(
        spec: spec,
        record: [for (final d in m['record'] as List) decision(d)],
        juries: [for (final d in (m['juries'] as List?) ?? const []) decision(d)],
        releases: [for (final e in (m['releases'] as List?) ?? const []) event(e)],
        names: {
          for (final e in ((m['names'] as Map?) ?? const {}).entries)
            if (int.tryParse('${e.key}') case final seat? when seat >= 0 && seat < seatCount && e.value is String)
              seat: cleanName(e.value as String, most: 40),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

class Decision {
  const Decision({
    required this.turn,
    required this.event,
    required this.witnesses,
    this.removal = false,
    this.among = const {},
    this.jury = false,
    this.verdict,
    this.backing = const [],
  });

  /// True for a jury proposal that carried: the hand's jurors, agreed
  /// by the table. Kept beside the record (the table's juries), not
  /// in it — it is authority for verdicts, not a move.
  final bool jury;

  /// The juror's verdict that settled this turn, when the players could
  /// not: it names the winning event, and the verifier checks the juror
  /// against the hand's jury.
  final V2Event? verdict;

  /// The turn settled, or the turn at which a departure was made.
  final V2Turn turn;

  /// The action (a pass, a play or a step of the deal), or the claim
  /// that carried the removal, one of [removalKinds].
  final V2Event event;

  /// What a removal is carried by: a boot, an absence, the leave
  /// itself, a held seat given to the escrow, or the game's end where
  /// nobody left could move it.
  static const removalKinds = {V2Kind.boot, V2Kind.absent, V2Kind.leave, V2Kind.escrow, V2Kind.ended};

  /// Who backed it, the author included.
  final Set<PublicKey> witnesses;

  /// For a removal, the signed word of everyone who backed it: the
  /// claims made at its turn (a boot, a claim of silence, the leave, a
  /// claim of the escrow, a vote that the game ends there) and the
  /// witnesses of one. A key in [witnesses] without its word here is no
  /// backer to the verifier (record.dart). Null only in a record kept
  /// before removals carried their backing (the record's version 1),
  /// where the keys are all there is.
  final List<V2Event>? backing;

  /// True when this is a departure rather than an action.
  final bool removal;

  /// The participants the decision was measured against, as this peer
  /// knew them: everyone who had sat down less the removals it knew of
  /// by that turn. Recorded so the verifier can check the majority
  /// against the set actually used, and that the set was a legitimate
  /// one — never smaller than the removals in the record allow.
  final Set<PublicKey> among;

  /// What this decision is, independent of which of several equivalent
  /// claims a peer happened to record: two peers' records match when
  /// their keys match. The action's id, or for a removal the seat and
  /// the turn — "seat 2 is out as of h0/t38" is the decision, and peers
  /// may hold different evidence for it: a boot pressed, a boot made
  /// for silence, the seat's own leave.
  String get key => jury
      ? 'jury@$turn#${event.id.substring(0, 8)}'
      : removal
          ? 'out@$turn#${event.seat}'
          : event.id;

  /// Canonical position in a record. The concurrent turns — a deal
  /// round's, the pass, the audit — settle in a different order at
  /// every peer; ordering by position (V2Turn.position), with
  /// departures ahead of the actions at the same position and those by
  /// seat, and the game's end after them all, makes every peer's record
  /// the same list.
  int compareTo(Decision other) {
    if (turn.hand != other.turn.hand) return turn.hand.compareTo(other.turn.hand);
    final a = turn.position;
    final b = other.turn.position;
    if (a != b) return a.compareTo(b);
    // The game's end is the last thing at its position. Claimed where
    // the table stopped, it comes after whatever settled beside it in a
    // set of turns open together — the audits the people said before a
    // held seat's audit stopped it — and nothing is recorded after it,
    // so it does not sort with the removals ahead of them.
    final endA = removal && event.kind == V2Kind.ended;
    final endB = other.removal && other.event.kind == V2Kind.ended;
    if (endA != endB) return endA ? 1 : -1;
    if (removal != other.removal) return removal ? -1 : 1;
    return event.seat.compareTo(other.event.seat);
  }

  @override
  String toString() =>
      '$turn ${jury ? 'JURY' : removal ? 'OUT' : 'ok'} $event by ${witnesses.length}${verdict != null ? ' by verdict' : ''}';
}

class Verification {
  const Verification({
    required this.ok,
    required this.reason,
    required this.winners,
    required this.ratings,
    required this.finalHolders,
    this.complete = true,
    this.ended = false,
  });

  final bool ok;
  final String reason;

  /// Whether the record ran to the end of the game. A partial record can
  /// still be [ok]: everything in it checked.
  final bool complete;

  /// Whether the record ends the game where nobody left could move the
  /// table: a majority of the people said so at the turn it stopped at
  /// (client.dart, _claimEnd). Not [complete] — the game did not run to
  /// its end, and nobody is rated on it — and not partial either:
  /// nothing more is owed.
  final bool ended;

  /// Winning seats, when the replay reached the end of the game.
  final List<int> winners;

  /// Rating change per human who ever held a seat: +1, −1, or 0.
  final Map<PublicKey, int> ratings;

  final List<SeatHolder> finalHolders;
}

/// Replays [record] against [spec].
///
/// The participants a majority is measured against at turn T are the
/// humans who sat down, less anyone removed by T — the client's rule.
/// One allowance: a peer settles the moment it holds a majority of the
/// set as it knows it, and a removal at the same position may not have
/// reached it yet, so a removed member who witnessed still counts, in
/// the denominator as well as the count. Nobody gains by that: it can
/// only raise the bar.
///
/// A decision the players could not carry may be carried by a juror's
/// verdict instead ([juries]: the jury proposals that carried at this
/// peer). Each jury must itself be carried by a majority of the
/// participants of its moment and be the draw its snapshot gives; a
/// verdict must be by a juror of a jury in force at its turn — the
/// hand's own, or the one before up to the turn the hand's own carried
/// at — about this turn and this seat, ruling for the very event
/// recorded.
///
/// A sealed record (docs/explanation/fair-deal.md) is replayed through the deal
/// as well, with [crypto]: every key's proof, every shuffle's
/// argument, every token, the lead card's declaration; then the
/// secrets from the hand's audit open every card, each play's token
/// must open the card it names, and the hands are checked as fully as
/// a seeded game's. Until a hand's audit is in, its plays can only be
/// checked as far as the rules allow without the hands, and the
/// verification is [Verification.complete] false.
///
/// [releases] are the escrow pieces released at this peer's table for
/// departed seats: a seat's secret the audits do not vouch for — one
/// removed at its own audit turn, after the others audited — is
/// rebuilt from them, a person's piece and a juror's.
///
/// Where accounts are checked (licence.dart), every person's seat must
/// carry a licence the service signed for its key, naming its account.
Verification verifyRecordV2(
  TableSpec spec,
  List<Decision> record, {
  bool allowPartial = false,
  List<Decision> juries = const [],
  DealCrypto? crypto,
  List<V2Event> releases = const [],
  TableReplay? replay,
}) =>
    _RecordVerifier(spec, record, allowPartial: allowPartial, juries: juries, crypto: crypto, releases: releases, replay: replay)
        .run();

/// One replay of a record ([verifyRecordV2]): the game rebuilt decision
/// by decision, and what the record has said so far that the decisions
/// after are held to.
class _RecordVerifier {
  _RecordVerifier(
    this.spec,
    this.record, {
    required bool allowPartial,
    required this.juries,
    required this.crypto,
    required this.releases,
    required this.replay,
  })  : // A record that ends the game where nobody could move the table ends
        // mid-hand, before the audit that opens every seat's cards: what it
        // says is checked as far as the cards known allow, as a partial
        // record's is, and then it is over ([Verification.ended]).
        partialOk = allowPartial || record.any((d) => d.removal && d.event.kind == V2Kind.ended),
        game = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target),
        holders = List.of(spec.seats),
        humans = {
          for (final h in spec.seats)
            if (h is HumanSeat) h.key,
        };

  final TableSpec spec;
  final List<Decision> record;
  final List<Decision> juries;
  final DealCrypto? crypto;
  final List<V2Event> releases;
  final TableReplay? replay;
  final bool partialOk;
  final HeartsGame game;
  final List<SeatHolder> holders;
  final Set<PublicKey> humans;
  final played = <Card>{};
  var index = 0;

  /// Every removal in the record, wherever it sits: the smallest set a
  /// peer could legitimately have measured against at a turn is everyone
  /// less all of these made by then — including ones recorded at the
  /// same position but later in the record's order ([readAhead]).
  final allRemovals = <PublicKey, V2Turn>{};

  /// The held seats the record gives to the escrow, by hand, for the
  /// same reason: a seat the hand will lose is opened from its pieces
  /// from the start of the replay ([feedSecrets]).
  final allEscrows = <int, Set<int>>{};

  /// Who said each held seat's keys, by hand: the seat's own juror from
  /// then on, as the table reads it (_asKeyed in deal_driver.dart).
  final keyedBy = <int, Map<int, PublicKey>>{};

  /// Fills [allRemovals], [allEscrows] and [keyedBy] from the whole
  /// record. Only once the record is past what it is refused for before
  /// any decision is read ([unreadable]): a removal names its seat by
  /// index.
  void readAhead() {
    for (final d in record) {
      if (!d.removal) continue;
      final h = spec.seats[d.event.seat];
      if (h is HumanSeat && !allRemovals.containsKey(h.key)) allRemovals[h.key] = d.turn;
    }
    for (final d in record) {
      if (d.removal && d.event.kind == V2Kind.escrow) allEscrows.putIfAbsent(d.turn.hand, () => {}).add(d.event.seat);
    }
    for (final d in record) {
      final e = d.event;
      if (d.removal || e.kind != V2Kind.deal || e.round != 0 || humans.contains(e.author)) continue;
      keyedBy.putIfAbsent(d.turn.hand, () => {})[e.seat] = e.author;
    }
  }

  /// Whether a hand the replay has been through could be checked only
  /// as far as the cards known allow: the verification is then partial.
  var incomplete = false;

  Verification fail(String why) => Verification(ok: false, reason: why, winners: const [], ratings: const {}, finalHolders: holders);

  Verification partial() =>
      Verification(ok: true, reason: 'verified so far', winners: const [], ratings: const {}, finalHolders: holders, complete: false);

  /// The decision that ends the game, where the record holds one.
  Decision? endedBy;

  Verification endedHere() => Verification(
      ok: true,
      reason: 'the game ended at ${endedBy!.turn}: nobody left could move it',
      winners: const [],
      ratings: const {},
      finalHolders: holders,
      complete: false,
      ended: true);

  bool atOrBefore(V2Turn a, V2Turn b) {
    if (a.hand != b.hand) return a.hand < b.hand;
    return a.position <= b.position;
  }

  Set<PublicKey> floorAt(V2Turn turn) => {
    for (final k in humans)
      if (!allRemovals.containsKey(k) || !atOrBefore(allRemovals[k]!, turn)) k,
  };

  /// The deal of the hand being replayed, at a sealed table.
  DealSession? deal;
  var auditsScanned = -1;

  /// The secrets the hand's audits carry, read ahead and held back:
  /// given to the deal for a departed seat when its steps are owed,
  /// and for everyone once the deal is dealt. Given sooner, a present
  /// seat's steps would be computed rather than checked.
  final pending = <int, Uint8List>{};

  /// Every juror the hand ever had, across redraws, filled in as the
  /// juries are checked below. Who *may* act for a bot seat, as
  /// against [sealedAt], which says whose each seat is.
  final jurors = <int, Set<PublicKey>>{};

  /// The jurors in force at [hand]: its own, or until it has any, the
  /// latest earlier hand's — the client's rule, a juror serves until
  /// relieved.
  Set<PublicKey> jurorsAt(int hand) {
    var latest = -1;
    for (final h in jurors.keys) {
      if (h <= hand && h > latest) latest = h;
    }
    return latest < 0 ? const {} : jurors[latest]!;
  }

  /// Where each hand's own jury carried: the earliest turn of its
  /// draws. A draw names the turn its proposer stood at, and is carried
  /// by a majority of the participants of that turn.
  final ownJuryAt = <int, V2Turn>{};

  /// Whether [who] may rule at [turn]: a juror of a jury in force there.
  /// The hand's own, across redraws; and, at turns up to the one the
  /// hand's own carried at — or the whole hand, if it never carried —
  /// the latest earlier hand's, since a jury serves until a later one
  /// carries. A table of two with one gone quiet carries no draw, so
  /// the old jury rules the seat out; then the one person left is the
  /// table's majority and carries the hand's own draw, which the juror
  /// who ruled need not be in: the jury's appeals and verdicts, as live
  /// play had them before the referee.
  ///
  /// At the turn the hand's own carried, the old jury still rules: the
  /// removal it rules there is what lets the one person left carry the
  /// draw at all, so at that position the verdict comes first at the
  /// table. Past it, a client that has carried the hand's own takes no
  /// verdict from a juror outside it (the client's verdicts), and
  /// a record holding one is not a table's.
  bool mayRule(PublicKey who, V2Turn turn) {
    final hand = turn.hand;
    if (jurors[hand]?.contains(who) ?? false) return true;
    final own = ownJuryAt[hand];
    if (own != null && !atOrBefore(turn, own)) return false;
    var before = -1;
    for (final h in jurors.keys) {
      if (h < hand && h > before) before = h;
    }
    return before >= 0 && jurors[before]!.contains(who);
  }

  /// The bot seats a jury holds at [hand], if it holds any: the ones
  /// that were bots when the hand began. A person who leaves turns
  /// their seat into one from the next hand, not this one — that hand
  /// is opened from their escrow in the clear (botSeatsAt in
  /// deal_driver.dart).
  List<int> botSeatsAt(int hand) => [
        for (var s = 0; s < seatCount; s++)
          if (switch (spec.seats[s]) {
            HumanSeat(:final key) => (allRemovals[key]?.hand ?? hand) < hand,
            BotSeat() => true,
          })
            s,
      ];

  /// A draw the hand carried, by its event's id.
  List<PublicKey>? juryById(String id, int hand) {
    for (final d in juries) {
      if (d.event.id == id && d.event.hand == hand) return d.event.jurors;
    }
    return null;
  }

  /// The draw each hand's deal was sealed to, as the table reads it
  /// (checkSealed in deal_driver.dart): named by the keys of the first
  /// person at the table, lowest seat first, whose keys for the hand
  /// are on the record — passing over a person removed at or before
  /// their own keys. Null where those keys name none, or there is
  /// nobody at the table to key the hand, its bot seats dealt in the
  /// open; not `said` where the record stops before them.
  final sealed = <int, ({bool said, String? jury})>{};
  ({bool said, String? jury}) sealedAt(int hand) => sealed.putIfAbsent(hand, () {
        final bots = botSeatsAt(hand);
        for (var s = 0; s < seatCount; s++) {
          if (bots.contains(s)) continue;
          final turn = V2Turn.deal(hand, 0, s);
          for (final d in record) {
            if (d.removal || d.turn != turn || d.event.kind != V2Kind.deal) continue;
            final named = d.event.body['jury'];
            return (said: true, jury: named is String ? named : null);
          }
          final out = allRemovals[(spec.seats[s] as HumanSeat).key];
          if (out != null && out.hand == hand && out.position <= turn.position) continue;
          return (said: false, jury: null);
        }
        // Nobody at the table to key it: sealed to no draw.
        return (said: true, jury: null);
      });

  /// Which juror holds which bot seat at [hand]: the draw the hand's
  /// deal was sealed to, read as the table reads it ([sealedAt]).
  Map<int, PublicKey> heldAt(int hand) {
    final at = sealedAt(hand);
    final jury = at.jury == null ? null : juryById(at.jury!, hand);
    return jury == null ? const {} : assignBots(jury, botSeatsAt(hand));
  }

  /// Grows each held seat's custodians as the table grows them
  /// (_applyGrowth in client.dart): after the list the seat's keys
  /// named, whoever the draws named in the hand's people's own plays
  /// brought in, in the order the record names them, and sorted within
  /// each draw. A seat's pieces are indexed by that list, a topped-up
  /// juror's among them, and a piece that juror releases counts only
  /// where its place is known. Read ahead from [from], since the
  /// replay opens a seat the hand will lose from the start; the places
  /// are the ones the table gave as each play carried. A draw named
  /// and not in hand holds up the ones after it, as at the table.
  void growCustodians(DealSession d, int hand, int from) {
    final named = <String>[];
    for (var i = from; i < record.length; i++) {
      final dec = record[i];
      final e = dec.event;
      if (dec.turn.hand != hand || !dec.turn.isPlay || dec.removal || e.kind != V2Kind.play) continue;
      final h = spec.seats[e.seat];
      final grew = e.body['grew'];
      if (h is! HumanSeat || h.key != e.author || grew is! List) continue;
      for (final id in grew) {
        if (id is String && !named.contains(id)) named.add(id);
      }
    }
    final added = <PublicKey>[];
    for (final id in named) {
      final jurors = juryById(id, hand);
      if (jurors == null) break;
      added.addAll(jurors.toList()..sort());
    }
    if (added.isEmpty) return;
    for (final seat in heldAt(hand).keys) {
      d.extendCustodians(seat, added);
    }
  }

  /// Why a seat's keys are not sealed where the table would take them
  /// (keysNameTheDraw in deal_driver.dart), or null: a person's name none,
  /// or a draw the hand carried that holds every bot seat; a held
  /// seat's name the draw the hand was sealed to, and come from the
  /// juror that draw names for the seat.
  String? keysNameTheDraw(V2Event e, int seat, int hand) {
    final named = e.body['jury'];
    if (named != null && named is! String) return 'hand $hand: seat $seat\'s keys name a draw that is not one';
    final bots = botSeatsAt(hand);
    if (!bots.contains(seat)) {
      if (named == null) return null;
      final jury = juryById(named as String, hand);
      if (jury == null) return 'hand $hand: seat $seat\'s keys are sealed to a draw the hand never carried';
      if (assignBots(jury, bots).length != bots.length) {
        return 'hand $hand: seat $seat\'s keys are sealed to a draw too small to hold the bot seats';
      }
      return null;
    }
    final at = sealedAt(hand);
    if (!at.said || named != at.jury) return 'hand $hand: seat $seat\'s keys are sealed to another draw than the hand\'s';
    if (heldAt(hand)[seat] != e.author) return 'hand $hand: seat $seat keyed by a juror the hand\'s draw does not name for it';
    return null;
  }

  /// The held seats the record has given to the escrow, by hand, as
  /// far as the replay has come ([takeRemovals]); and those given up at
  /// one of their deal steps.
  final escrowedAt = <int, Set<int>>{};
  final escrowedInDeal = <int, Set<int>>{};

  /// Whether [who] may act for [seat] at [hand]: the person sitting
  /// there, or the juror holding it when it is a bot seat the jury
  /// holds. A bot seat nobody holds is acted for by nobody, and its
  /// steps are recomputed rather than read.
  bool mayAct(int seat, PublicKey who, int hand) {
    final holder = holders[seat];
    if (holder is HumanSeat) return holder.key == who;
    if (!heldAt(hand).containsKey(seat) || !jurorsAt(hand).contains(who)) return false;
    // As at the table (_mayAct in client.dart): before the seat's keys,
    // any juror the hand had, redraws included; from then on only the
    // juror that made them, until the record gives the seat to the
    // escrow; and from then on any juror that has the key, from
    // whatever draw, the seat's own included.
    final keyed = keyedBy[hand]?[seat];
    if (keyed == null) return true;
    return (escrowedAt[hand]?.contains(seat) ?? false) || who == keyed;
  }

  DealSession startDeal() => deal = DealSession(
    crypto!,
    tableId: spec.id,
    tableSeed: spec.seed,
    hand: game.handNumber,
    seats: [
      for (var s = 0; s < seatCount; s++)
        switch (holders[s]) {
          HumanSeat(:final key) => HumanDealSeat(key),
          BotSeat() => BotDealSeat(key: heldAt(game.handNumber)[s]),
        },
    ],
    leadCard: twoOfClubs.index,
    // Frozen with the rest: a game kept then has its passes as they were.
    readsOldPasses: true,
  );

  /// The hand's audits, read ahead once every key is in: the secrets
  /// they carry open the cards the replay needs before it gets there
  /// — a departed seat's hand for its bot's plays, above all.
  void scanAudits(DealSession d) {
    final hand = game.handNumber;
    if (auditsScanned == hand) return;
    for (var s = 0; s < seatCount; s++) {
      if (!d.hasKeys(s)) return;
    }
    auditsScanned = hand;
    pending.clear();
    for (var i = index; i < record.length && record[i].turn.hand == hand; i++) {
      final e = record[i].event;
      if (e.kind != V2Kind.deal || record[i].removal || e.round != 4) continue;
      // An audit's secrets are the deal's fields, not ones every side
      // reads (V2Event.wellFormed): one that is not base64 opens
      // nothing, and the check of the hand says what it lacks.
      // Read as far as it reads, as before: no secret, nothing; a bad
      // entry among the known, none after it.
      final secret = e.body['secret'];
      if (secret is! String) continue;
      final known = e.body['known'];
      try {
        pending[e.seat] = Uint8List.fromList(base64.decode(secret));
        if (known is Map) {
          for (final MapEntry(:key, :value) in known.entries) {
            if (key is! String || value is! String) break;
            pending[int.parse(key)] = Uint8List.fromList(base64.decode(value));
          }
        }
      } on FormatException {
        continue;
      }
    }
  }

  /// Gives the deal the secrets it may have now: a departed seat's,
  /// or everyone's once dealt — from the audits read ahead, and from
  /// the pieces released for a seat that is gone, or that the record
  /// removes later in the hand: with the deal dealt, its steps all
  /// checked, a seat the hand will lose may be opened from its escrow
  /// ahead of time, since the replay needs every hand from the start.
  void feedSecrets(DealSession d, {required bool all}) {
    for (final e in List.of(pending.entries)) {
      if (all || d.awaitsSecret(e.key)) {
        if (d.provideSecret(e.key, e.value)) pending.remove(e.key);
      }
    }
    for (final r in releases) {
      if (r.kind != V2Kind.release || r.hand != game.handNumber) continue;
      // A release names its seat by number, and a number past the
      // table's is none of its seats.
      final about = r.about;
      if (about < 0 || about >= seatCount) continue;
      if (all && !d.gone.contains(about) && !d.knowsSecret(about)) {
        final h = holders[about];
        if (h is HumanSeat && allRemovals[h.key]?.hand == game.handNumber) d.seatLeft(about);
        // A bot seat a juror held that the record gives to the
        // escrow this hand — its holder quiet, or slow to play. Its
        // audit is settled with nothing said, the pieces having
        // opened it in the clear, so its pieces are its whole
        // account. As with a person's: taken only from the
        // custodians the seat's own deal steps named, and what they
        // rebuild opens nothing unless it is the secret behind the
        // key the seat dealt with — the one its own audit would have
        // said. A held seat the record did not give up owes its own
        // audit, as at the table (_botActs in client.dart), and
        // pieces are no substitute.
        if (h is BotSeat && (allEscrows[game.handNumber]?.contains(about) ?? false)) d.seatLeft(about);
      }
      if (!d.awaitsSecret(about)) continue;
      d.acceptRelease({'about': about, 'holder': r.author, 'share': r.body['share']});
    }
  }

  /// Whether a decision carries: a strict majority of [among], the set
  /// the peer measured against — which must be a legitimate one, every
  /// human who sat down less some of the removals made by [turn], never
  /// fewer than that.
  bool carried(Set<PublicKey> witnesses, V2Turn turn, Set<PublicKey> among) {
    if (among.isEmpty || !humans.containsAll(among)) return false;
    if (!among.containsAll(floorAt(turn))) return false;
    return witnesses.intersection(among).length >= among.length ~/ 2 + 1;
  }

  /// Whether [d] is carried by a verdict: a juror of a jury in force at
  /// its turn ([mayRule]) ruled for exactly this event at exactly this
  /// turn.
  bool byVerdict(Decision d) {
    final v = d.verdict;
    if (v == null || v.kind != V2Kind.verdict) return false;
    if (!mayRule(v.author, d.turn)) return false;
    try {
      if (v.turn != d.turn || v.seat != d.event.seat) return false;
      if ((v.side == 'removal') != d.removal) return false;
      final ruled = v.ruled;
      return ruled != null && ruled.id == d.event.id;
    } catch (_) {
      return false;
    }
  }

  int playIndex() => game.tricksPlayed * seatCount + game.trick.length;

  /// A bot's move, recomputed. Null when it could be; otherwise why not:
  /// at a sealed table a departed seat's hand may not be open yet.
  String? botActs(int seat, {required bool passing}) {
    final d = deal;
    if (d != null && !game.knowsHand(seat)) {
      // The pass into the seat first, as the client does; then the
      // hand as the engine holds it: dealt while the pass is
      // unresolved, current during play.
      if (!openPassInto(d, game, seat)) return 'the pass into seat $seat was never opened';
      final cards = game.phase == Phase.playing ? d.handOf(seat) : d.dealtHandOf(seat);
      if (cards == null) return 'seat $seat\'s hand was never opened';
      game.revealHand(seat, [for (final i in cards) Card.deck[i]]);
    }
    final bot = Bot(persona: (holders[seat] as BotSeat).persona);
    if (passing) {
      final cards = bot.choosePass(game.handOf(seat));
      if (d != null) {
        d.passOpen(seat, (seat + game.passDirection.seatOffset) % seatCount, [for (final c in cards) d.positionOf(seat, c.index)!]);
        final leader = d.leader;
        if (leader != null) game.declareLeader(leader);
      }
      game.setPass(seat, cards);
    } else {
      final view = BotView(
        seat: seat,
        hand: game.handOf(seat),
        trick: game.trick,
        played: played,
        heartsBroken: game.heartsBroken,
        isFirstTrick: game.isFirstTrick,
        taken: game.taken,
      );
      final card = bot.chooseCard(view, game.legalPlaysFor(seat));
      if (d != null) d.playOpen(seat, d.positionOf(seat, card.index)!);
      replay?.played(game.handNumber, seat, card);
      game.play(seat, card);
      played.add(card);
    }
    return null;
  }

  void sweep() {
    if (game.pendingTrick != null) game.collectTrick();
    if (game.phase == Phase.handOver) {
      played.clear();
      if (!spec.sealed) {
        replay?.ended(game);
        game.nextHand();
      }
    }
  }

  /// Who backed removal [d], by their own signed word: the claims at its
  /// turn against its seat and the witnesses of one. Claims of one way
  /// out back each other — a boot, a claim of silence or of the escrow;
  /// the leave alone; a vote that the game ends there, where it says it
  /// does — as they do at the table. A key the record names without its
  /// word behind it is no backer. A record kept before removals carried
  /// their backing names its backers by key alone, and those are all
  /// there is ([Decision.backing]).
  Set<PublicKey> backersOf(Decision d) {
    final backing = d.backing;
    if (backing == null) return {...d.witnesses};
    final ways = switch (d.event.kind) {
      V2Kind.ended => const {V2Kind.ended},
      V2Kind.leave => const {V2Kind.leave},
      _ => const {V2Kind.boot, V2Kind.absent, V2Kind.escrow},
    };
    final claims = [
      for (final e in [d.event, ...backing])
        if (ways.contains(e.kind) && e.turn == d.turn && e.seat == d.event.seat) e,
    ];
    final ids = {for (final c in claims) c.id};
    return {
      for (final c in claims)
        if (c.kind != V2Kind.ended || c.body['vote'] == true) c.author,
      for (final w in backing)
        if (w.kind == V2Kind.witness && w.turn == d.turn && ids.contains(w.witnessed)) w.author,
    };
  }

  /// Applies the departures recorded next, each checked against the
  /// participants at the turn it names.
  String? takeRemovals() {
    while (index < record.length && record[index].removal) {
      final d = record[index++];
      final e = d.event;
      final seat = e.seat;
      // The game's end, where nobody left could move the table: claimed
      // at the turn it stopped at by a person there, and carried by a
      // majority of them, as a boot is. Nobody rules on it — there was
      // no jury left to — and nothing comes after it.
      if (e.kind == V2Kind.ended) {
        if (!humans.contains(e.author)) return 'the game ended by someone not at the table';
        if (e.turn != d.turn) return 'the game ended at ${d.turn} by a claim made at ${e.turn}';
        final backers = backersOf(d);
        if (!carried(backers, d.turn, d.among)) {
          return 'the game ended at ${d.turn} without a majority behind it (${backers.length} of ${d.among.length})';
        }
        if (index < record.length) return 'the record goes on past the game\'s end at ${d.turn}';
        endedBy = d;
        return null;
      }
      final holder = holders[seat];
      if (holder is! HumanSeat) {
        // A held seat given to the escrow: a claim by a person at the
        // table, carried by the people or ruled by the jury as a boot is
        // (_carryEscrow in client.dart). The seat is the escrow's from
        // there to the end of the hand.
        if (e.kind != V2Kind.escrow) continue;
        if (!heldAt(d.turn.hand).containsKey(seat)) return 'an escrow of seat $seat, which no juror held';
        if (escrowedAt[d.turn.hand]?.contains(seat) ?? false) return 'seat $seat given to the escrow twice in hand ${d.turn.hand}';
        if (!humans.contains(e.author)) return 'an escrow of seat $seat claimed by someone not at the table';
        final backers = backersOf(d);
        if (!carried(backers, d.turn, d.among) && !byVerdict(d)) {
          return 'an escrow of seat $seat at ${d.turn} without a majority behind it (${backers.length} of ${d.among.length})';
        }
        escrowedAt.putIfAbsent(d.turn.hand, () => {}).add(seat);
        if (d.turn.isDeal) escrowedInDeal.putIfAbsent(d.turn.hand, () => {}).add(seat);
        if (d.turn.hand == game.handNumber) deal?.seatLeft(seat);
        continue;
      }
      if (e.kind == V2Kind.escrow) return 'an escrow of seat $seat, which is a person\'s';
      if (e.kind == V2Kind.leave) {
        // The leaver's own word, carried as a boot is: a majority of the
        // people at its turn, the leaver's signature its own vote
        // (_settleLeave in client.dart).
        if (e.author != holder.key) return 'a leave signed by someone else';
        if (e.turn != d.turn) return 'a leave recorded at ${d.turn}, said at ${e.turn}';
        final backers = backersOf(d);
        if (!carried(backers, d.turn, d.among)) {
          return 'a leave of seat $seat at ${d.turn} without a majority behind it (${backers.length} of ${d.among.length})';
        }
      } else {
        final backers = backersOf(d)..remove(holder.key);
        if (!carried(backers, d.turn, d.among) && !byVerdict(d)) {
          return 'a ${e.kind.name} of seat $seat at ${d.turn} without a majority behind it '
              '(${backers.length} of ${d.among.length})';
        }
      }
      holders[seat] = BotSeat(spec.replacementFor(seat));
      deal?.seatLeft(seat);
    }
    return null;
  }

  /// The next decision, which must be a human's action at [turn] by
  /// the key holding [seat], carried; or the reason it is not.
  (Decision?, String?) takeAction(V2Turn turn, int seat, V2Kind kind, {String? at}) {
    if (index >= record.length) return (null, partialOk ? null : 'the record ends with seat $seat to ${kind.name}');
    final d = record[index++];
    final e = d.event;
    if (e.kind != kind) return (null, 'expected a ${kind.name}, saw ${e.kind.name}');
    if (!mayAct(seat, e.author, d.turn.hand) || e.seat != seat) {
      return (null, 'a ${kind.name} by a key that did not hold seat $seat');
    }
    if (d.turn != turn) return (null, 'a ${kind.name} recorded at $turn as ${d.turn}');
    if (!carried(d.witnesses, turn, d.among) && !byVerdict(d)) {
      return (null, 'a ${kind.name} at $turn by seat $seat without a majority behind it (${d.witnesses.length} of ${d.among.length})');
    }
    return (d, null);
  }

  /// Whether the next decision is one of the current hand's audits.
  bool nextIsAudit() =>
      index < record.length && record[index].turn.hand == game.handNumber && record[index].turn.isAudit && !record[index].removal;

  /// The hand's audits, one per person still seated, each the secret
  /// behind the seat's key; null when they are all in and open every
  /// card, else the verification to return.
  Verification? takeAudits() {
    final d = deal!;
    final audited = <int>{};
    while (nextIsAudit()) {
      final dec = record[index++];
      final e = dec.event;
      final seat = dec.turn.auditSeat;
      if (e.kind != V2Kind.deal || e.round != 4 || e.seat != seat) return fail('expected an audit by seat $seat, saw ${e.kind.name}');
      if (!audited.add(seat)) return fail('hand ${game.handNumber}: seat $seat audited twice');
      // A seat the record gave to the escrow is audited from its pieces,
      // with nothing said (_isEscrowedAudit in client.dart).
      if (escrowedAt[dec.turn.hand]?.contains(seat) ?? false) return fail('an audit of seat $seat, which the record gave to the escrow');
      if (!mayAct(seat, e.author, dec.turn.hand)) return fail('an audit by a key that did not hold seat $seat');
      if (!carried(dec.witnesses, dec.turn, dec.among) && !byVerdict(dec)) {
        return fail('an audit at ${dec.turn} by seat $seat without a majority behind it (${dec.witnesses.length} of ${dec.among.length})');
      }
      if (!d.acceptAudit(Map<String, Object?>.from(e.body))) {
        return fail('hand ${game.handNumber}: an audit by seat $seat that is not the secret behind its key');
      }
      final why = takeRemovals();
      if (why != null) return fail(why);
      if (endedBy != null) return endedHere();
    }
    final ended = index >= record.length;
    for (var s = 0; s < seatCount; s++) {
      if (holders[s] is HumanSeat && !d.knowsSecret(s)) {
        if (ended && partialOk) return partial();
        return fail('hand ${game.handNumber}: seat $s never audited');
      }
    }
    if (d.fullDeal == null) return fail('hand ${game.handNumber}: the audit does not open every card');
    return null;
  }

  /// Whether the record gives the hand up in its deal: a held seat
  /// given to the escrow at one of its own deal steps, with a step of
  /// the deal still to take — its word on the lead card is the last.
  /// Nobody else can take it (its juror drew the key), and the table
  /// gives the hand up (_carryEscrow in client.dart). The escrow is on
  /// the record; nothing here is worked out from what is missing.
  bool givenUpUndealt(DealSession d) =>
      (escrowedInDeal[game.handNumber] ?? const <int>{}).any((s) => !d.hasDeclared(s));

  /// Why a decision in the record cannot be read at all, or null. Each
  /// names its seat by index, and the replay reads the seat by it from
  /// the start, ahead of where the decision is checked ([readAhead],
  /// [growCustodians]); and a removal is carried by a claim that can
  /// carry one ([Decision.removalKinds]).
  String? unreadable() {
    for (final d in record) {
      final e = d.event;
      final seat = e.body['seat'];
      if (seat is! int || seat < 0 || seat >= seatCount) return 'the ${e.kind.name} at ${d.turn} names no seat at the table';
      if (d.removal && !Decision.removalKinds.contains(e.kind)) return 'the ${e.kind.name} at ${d.turn} is recorded as a removal';
    }
    return null;
  }

  /// The replay, decision by decision, to the verification it comes to.
  Verification run() {
    if (spec.sealed && crypto == null) return fail('a sealed record needs the deal\'s cryptography to check');
    // Every seat an account's, by the service's word that its key is one
    // of the account's devices (licence.dart): what makes the names, the
    // ratings and the result the accounts'. No clock to hold a licence's
    // date to: a record is read long after it ran out.
    final unlicensed = spec.licenceProblem();
    if (unlicensed != null) return fail(unlicensed);
    final unread = unreadable();
    if (unread != null) return fail(unread);
    readAhead();

    final jury = checkJuries();
    if (jury != null) return jury;
    while (game.phase != Phase.gameOver) {
      final why = takeRemovals();
      if (why != null) return fail(why);
      if (endedBy != null) return endedHere();
      final stop = switch (game.phase) {
        Phase.dealing => dealStep(),
        Phase.passing => passStep(),
        Phase.handOver => handOverStep(),
        _ => playStep(),
      };
      if (stop != null) return stop;
    }
    if (deal != null) {
      // The last hand is audited too — after whatever the record removes
      // at its audits, which comes first at their position as at every
      // hand's. Taken straight to the audits, a claim for the escrow at
      // one of them would stop the replay before any audit, and leave the
      // hand's audits and that claim unchecked.
      final why = takeRemovals();
      if (why != null) return fail(why);
      if (endedBy != null) return endedHere();
      final v = takeAudits();
      if (v != null) return v;
      replay?.ended(game, deal);
    }
    // And nothing after: a decision the replay never reached is one it
    // never checked.
    if (index < record.length) {
      final d = record[index];
      return fail('the record goes on past the end of the game: ${d.removal ? 'a removal' : 'a ${d.event.kind.name}'} at ${d.turn}');
    }
    if (incomplete) return partial();

    final winners = game.winners;
    final ratings = <PublicKey, int>{};
    final botWon = winners.any((s) => holders[s] is BotSeat);
    for (var s = 0; s < seatCount; s++) {
      final original = spec.seats[s];
      if (original is! HumanSeat) continue;
      ratings[original.key] = botWon ? 0 : (winners.contains(s) ? 1 : -1);
    }
    return Verification(ok: true, reason: 'verified', winners: winners, ratings: ratings, finalHolders: holders);
  }

  /// Every jury the table carried, checked: drawn as its snapshot
  /// gives, carried by a majority of its moment. Null when they all
  /// are, else the verification to return.
  Verification? checkJuries() {
    for (final d in juries) {
      final e = d.event;
      if (!d.jury || e.kind != V2Kind.jury) return fail('a jury that is not a jury proposal');
      if (!humans.contains(e.author)) return fail('a jury proposed by someone not at the table');
      List<PublicKey> snapshot;
      List<PublicKey> drawn;
      try {
        snapshot = e.snapshot;
        drawn = e.jurors;
      } catch (_) {
        return fail('a malformed jury proposal');
      }
      if (snapshot.any(humans.contains)) return fail('a jury drawn from the table itself');
      final expected = drawJury(spec.seed, e.hand, snapshot);
      if (expected.length != drawn.length || Iterable<int>.generate(drawn.length).any((i) => expected[i] != drawn[i])) {
        return fail('a jury for hand ${e.hand} that is not the draw its snapshot gives');
      }
      if (!carried(d.witnesses, d.turn, d.among)) {
        return fail('a jury for hand ${e.hand} without a majority behind it (${d.witnesses.length} of ${d.among.length})');
      }
      jurors.putIfAbsent(e.hand, () => {}).addAll(drawn);
      final at = ownJuryAt[e.hand];
      if (at == null || e.turn.position < at.position) ownJuryAt[e.hand] = e.turn;
    }
    return null;
  }

  /// The next step of a sealed hand's deal; or, the deal done, the hand
  /// dealt. Null to go on, else the verification to return.
  Verification? dealStep() {
    final d = deal ?? startDeal();
    scanAudits(d);
    feedSecrets(d, all: false);
    final dealDone =
        !(index < record.length && record[index].turn.hand == game.handNumber && record[index].turn.isDeal) ||
        d.phase == DealPhase.dealt ||
        d.phase == DealPhase.audited;
    if (dealDone) {
      if (d.phase != DealPhase.dealt && d.phase != DealPhase.audited) {
        if (partialOk && index >= record.length) return partial();
        // A hand given up in its deal: a bot seat's juror went with
        // a step of the seat still owed, and nobody else can take it
        // — the juror drew the key. The table gives the hand up
        // unscored and deals the next (giveUpUndealtHand in
        // deal_driver.dart), with no audit, since the seat that stopped
        // it cannot be opened to show anything. So the record goes
        // on to a later hand with this one's deal short, and that
        // is a hand over, not a deal left unfinished
        // (docs/explanation/live-play.md).
        //
        // Only where the record gives a held seat to the escrow with
        // a step of the deal still owed. Every other step has
        // somebody to take it: a person's is theirs until they are
        // removed, and the record shows the removal; a seat nobody
        // holds is worked out by everyone. And nothing of the hand
        // was passed or played, so there is nothing to check of it
        // beyond the steps that were said.
        if (index < record.length && record[index].turn.hand > game.handNumber && givenUpUndealt(d)) {
          game.abandonHand();
          deal = null;
          return null;
        }
        return fail('hand ${game.handNumber}: the deal is not complete (${d.phase.name})');
      }
      // A hand whose audits follow its deal with nothing in between
      // never began: nobody could lead it, so the table opened it to
      // find out why and gave it up (docs/explanation/fair-deal.md, and
      // giveUpHand in deal_driver.dart). Two things make that legitimate,
      // and both are in the record: every seat's own signed word put
      // the lead card nowhere, and the deal those audits open shows
      // one of them holding it. What the record must not then contain
      // is the hand played on with every card in the open, and it
      // cannot: the audits are where the hand ends.
      final givenUp = nextIsAudit();
      // A newcomer's piece is released like any other, and has to be
      // placed here as the table placed it, or a seat given to the
      // escrow and opened at the table from a topped-up juror's piece
      // would never open here.
      growCustodians(d, game.handNumber, index);
      feedSecrets(d, all: true);
      if (givenUp) {
        if (!d.leadDisclaimed) {
          return fail('hand ${game.handNumber}: opened before it began, though a seat said where the lead card was');
        }
        final v = takeAudits();
        if (v != null) return v;
        if (d.lied == null) {
          return fail('hand ${game.handNumber}: given up, though the open deal shows a seat that could have led it');
        }
        game.abandonHand();
        deal = null;
        return null;
      }
      final leader = d.leader;
      if (leader == null) return fail('hand ${game.handNumber}: nobody declared the lead card');
      final hands = <List<Card>?>[];
      for (var s = 0; s < seatCount; s++) {
        final cards = d.dealtHandOf(s);
        if (cards == null && !partialOk) return fail('hand ${game.handNumber}: seat $s\'s cards were never opened');
        if (cards == null) incomplete = true;
        hands.add(cards == null ? null : [for (final i in cards) Card.deck[i]]);
      }
      game.declareLeader(leader);
      game.deal(hands);
      return null;
    }
    // The next step owed: the first unsettled seat of the round the
    // deal is at, in the order the table opens them.
    final round = switch (d.phase) {
      DealPhase.keys => 0,
      DealPhase.shuffles => 1,
      DealPhase.tokens => 2,
      _ => 3,
    };
    if (index >= record.length) return partialOk ? partial() : fail('the record ends mid-deal');
    final next = record[index];
    final e = next.event;
    if (e.kind != V2Kind.deal || !next.turn.isDeal) return fail('hand ${game.handNumber}: expected a deal step, saw ${e.kind.name}');
    if (next.turn.dealRound != round || e.round != round) {
      return fail('hand ${game.handNumber}: a deal step of round ${e.round} where round $round is owed');
    }
    final seat = next.turn.dealSeat;
    final (dec, whyNot) = takeAction(next.turn, seat, V2Kind.deal);
    if (whyNot != null) return fail(whyNot);
    if (dec == null) return partial();
    if (round == 0) {
      final why = keysNameTheDraw(e, seat, game.handNumber);
      if (why != null) return fail(why);
    }
    final b = Map<String, Object?>.from(e.body);
    final ok = switch (round) {
      0 => d.acceptKeys(b),
      1 => d.acceptShuffle(b),
      2 => d.acceptTokens(b),
      _ => d.acceptDeclaration(b),
    };
    if (!ok) return fail('hand ${game.handNumber}: a deal step by seat $seat that does not verify (round $round)');
    return null;
  }

  /// The pass: a bot seat nobody holds worked out, the next pass taken.
  /// Null to go on, else the verification to return.
  Verification? passStep() {
    for (var s = 0; s < seatCount; s++) {
      // A bot seat a juror holds said its pass in the record, like a
      // person's; only one nobody holds is recomputed here.
      if (holders[s] is BotSeat && heldAt(game.handNumber)[s] == null && !game.hasPassed(s)) {
        final whyNot = botActs(s, passing: true);
        if (whyNot != null) return partialOk ? partial() : fail(whyNot);
      }
    }
    if (game.phase != Phase.passing) return null;
    if (index >= record.length) return partialOk ? partial() : fail('the record ends mid-pass');
    final d = record[index++];
    final e = d.event;
    if (e.kind != V2Kind.pass) return fail('expected a pass, saw ${e.kind.name}');
    if (!mayAct(e.seat, e.author, d.turn.hand)) return fail('a pass by a key that did not hold seat ${e.seat}');
    if (!carried(d.witnesses, d.turn, d.among) && !byVerdict(d)) {
      return fail(
        'a pass at ${d.turn} by seat ${e.seat} without a majority behind it '
        '(${d.witnesses.length} of ${d.among.length})',
      );
    }
    final dl = deal;
    if (dl != null) {
      final b = Map<String, Object?>.from(e.body);
      final to = (e.seat + game.passDirection.seatOffset) % seatCount;
      if (b['from'] != e.seat || b['to'] != to) return fail('a pass by seat ${e.seat} not to seat $to');
      final positions = [for (final p in b['positions'] as List) p as int];
      if (positions.length != passSize || !dl.acceptPass(b)) return fail('a pass by seat ${e.seat} the deal does not take');
      final cards = <Card>[];
      for (final p in positions) {
        final c = dl.openedCardAt(p);
        if (c == null) break;
        cards.add(Card.deck[c]);
      }
      final leader = dl.leader;
      if (leader != null) game.declareLeader(leader);
      // As with a play: a bot seat a juror holds said this pass, so
      // the policy on its opened hand has to give the same three.
      if (heldAt(game.handNumber)[e.seat] != null && cards.length == passSize && game.knowsHand(e.seat)) {
        final want = Bot(persona: (holders[e.seat] as BotSeat).persona).choosePass(game.handOf(e.seat));
        if (want.toSet().length != cards.toSet().length || !want.every(cards.contains)) {
          return fail('a pass by seat ${e.seat} that the policy does not pass');
        }
      }
      try {
        game.setPass(e.seat, cards.length == passSize ? cards : null);
      } catch (_) {
        return fail('an illegal pass by seat ${e.seat}');
      }
      if (cards.length != passSize) incomplete = true;
      return null;
    }
    try {
      game.setPass(e.seat, [for (final c in e.body['cards'] as List) Card.parse(c as String)]);
    } catch (_) {
      return fail('an illegal pass by seat ${e.seat}');
    }
    return null;
  }

  /// The hand over: a sealed hand's audits, then the next hand. Null to
  /// go on, else the verification to return.
  Verification? handOverStep() {
    // A sealed hand ends with its audits, one per person still
    // seated; then the next deal.
    final v = takeAudits();
    if (v != null) return v;
    // Every card open now: what each seat was dealt, and held after
    // the pass, for whoever is looking at the game afterwards.
    replay?.ended(game, deal);
    game.nextHand();
    deal = null;
    return null;
  }

  /// The next card: a bot seat nobody holds worked out, a person's or a
  /// held seat's taken from the record. Null to go on, else the
  /// verification to return.
  Verification? playStep() {
    final seat = game.currentSeat!;
    if (holders[seat] is BotSeat && heldAt(game.handNumber)[seat] == null) {
      final whyNot = botActs(seat, passing: false);
      if (whyNot != null) return partialOk ? partial() : fail(whyNot);
      sweep();
      return null;
    }
    if (index >= record.length) return partialOk ? partial() : fail('the record ends with seat $seat to play');
    final d = record[index++];
    final e = d.event;
    if (e.kind != V2Kind.play) return fail('expected a play, saw ${e.kind.name}');
    if (!mayAct(seat, e.author, d.turn.hand) || e.seat != seat) {
      return fail('a play by a key that did not hold seat $seat');
    }
    final turn = V2Turn.play(game.handNumber, playIndex());
    if (d.turn != turn) return fail('a play recorded at $turn as ${d.turn}');
    if (!carried(d.witnesses, turn, d.among) && !byVerdict(d)) {
      return fail(
        'a play at $turn by seat $seat without a majority behind it '
        '(${d.witnesses.length} of ${d.among.length})',
      );
    }
    final card = Card.parse(e.body['card'] as String);
    final dl = deal;
    if (dl != null) {
      final opened = dl.acceptPlay(seat, Map<String, Object?>.from(e.body));
      if (opened != card.index) return fail('a play at $turn by seat $seat whose token does not open $card');
      if (game.knowsHand(seat)) {
        if (!game.legalPlaysFor(seat).contains(card)) return fail('an illegal play by seat $seat: $card');
      } else {
        if (!game.allows(seat, card)) return fail('an illegal play by seat $seat: $card');
        incomplete = true;
      }
    } else if (!game.legalPlaysFor(seat).contains(card)) {
      return fail('an illegal play by seat $seat: $card');
    }
    // A bot seat a juror holds said this card rather than everyone
    // working it out, so this is where it is checked: on the hand the
    // audit opened, the policy has to give the same card. A juror
    // playing a bot badly for somebody at the table is caught here,
    // at the end of the hand rather than at the turn — which is the
    // price of the hand being hidden (docs/explanation/live-play.md).
    if (heldAt(game.handNumber)[seat] != null && game.knowsHand(seat)) {
      final want = Bot(persona: (holders[seat] as BotSeat).persona).chooseCard(
        BotView(
          seat: seat,
          hand: game.handOf(seat),
          trick: game.trick,
          played: played,
          heartsBroken: game.heartsBroken,
          isFirstTrick: game.isFirstTrick,
          taken: game.taken,
        ),
        game.legalPlaysFor(seat),
      );
      if (want != card) return fail('a play at $turn by seat $seat that the policy does not play: $card, not $want');
    }
    replay?.played(game.handNumber, seat, card);
    game.play(seat, card);
    played.add(card);
    sweep();
    return null;
  }
}


