/// A finished game, checked by anyone.
///
/// The record is the table spec and the decisions in order. Replaying
/// it rebuilds the game: every human action must be signed by the key
/// that held the seat and legal under the engine at that point, every
/// removal must carry the majority the participants of the moment
/// required, and every bot move is recomputed rather than read. The
/// ratings fall out of the replay by doc 04's two rules.
library;

import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import 'client.dart';
import 'events.dart';
import 'jury.dart';
import 'sealed_pass.dart';
import 'signing.dart';
import 'spec.dart';

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
/// verdict must be by a juror of the hand, about this turn and this
/// seat, ruling for the very event recorded.
///
/// A sealed record (docs/03-fair-deal.md) is replayed through the deal
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
Verification verifyRecord(
  TableSpec spec,
  List<Decision> record, {
  bool allowPartial = false,
  List<Decision> juries = const [],
  DealCrypto? crypto,
  List<TableEvent> releases = const [],
  TableReplay? replay,
}) {
  // A record that ends the game where nobody could move the table ends
  // mid-hand, before the audit that opens every seat's cards: what it
  // says is checked as far as the cards known allow, as a partial
  // record's is, and then it is over ([Verification.ended]).
  if (record.any((d) => d.removal && d.event.kind == EventKind.ended)) allowPartial = true;
  final game = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target);
  final holders = List.of(spec.seats);
  final humans = {
    for (final h in spec.seats)
      if (h is HumanSeat) h.key,
  };
  final removedAt = <PublicKey, TurnId>{};
  final played = <Card>{};
  var index = 0;

  Verification fail(String why) => Verification(ok: false, reason: why, winners: const [], ratings: const {}, finalHolders: holders);

  if (spec.sealed && crypto == null) return fail('a sealed record needs the deal\'s cryptography to check');

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

  bool atOrBefore(TurnId a, TurnId b) {
    if (a.hand != b.hand) return a.hand < b.hand;
    return a.position <= b.position;
  }

  // Every removal in the record, wherever it sits: the smallest set a
  // peer could legitimately have measured against at a turn is everyone
  // less all of these made by then — including ones recorded at the
  // same position but later in the record's order.
  final allRemovals = <PublicKey, TurnId>{};
  for (final d in record) {
    if (!d.removal) continue;
    final h = spec.seats[d.event.seat];
    if (h is HumanSeat && !allRemovals.containsKey(h.key)) allRemovals[h.key] = d.turn;
  }
  // And the held seats the record gives to the escrow, by hand, for
  // the same reason: a seat the hand will lose is opened from its
  // pieces from the start of the replay ([feedSecrets]).
  final allEscrows = <int, Set<int>>{};
  for (final d in record) {
    try {
      if (d.removal && d.event.kind == EventKind.escrow) allEscrows.putIfAbsent(d.turn.hand, () => {}).add(d.event.seat);
    } catch (_) {}
  }
  Set<PublicKey> floorAt(TurnId turn) => {
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

  /// The bot seats a jury holds at [hand], if it holds any: the ones
  /// that were bots when the hand began. A person who leaves turns
  /// their seat into one from the next hand, not this one — that hand
  /// is opened from their escrow in the clear (_botSeatsAt in
  /// client.dart).
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
  /// (_checkSealed in client.dart): named by the keys of the first
  /// person at the table, lowest seat first, whose keys for the hand
  /// are on the record — passing over a person removed at or before
  /// their own keys. Null where those keys name none, or there is
  /// nobody at the table to key the hand, its bot seats dealt in the
  /// open; not [said] where the record stops before them.
  final sealed = <int, ({bool said, String? jury})>{};
  ({bool said, String? jury}) sealedAt(int hand) => sealed.putIfAbsent(hand, () {
        final bots = botSeatsAt(hand);
        for (var s = 0; s < seatCount; s++) {
          if (bots.contains(s)) continue;
          final turn = TurnId.deal(hand, 0, s);
          for (final d in record) {
            if (d.removal || d.turn != turn || d.event.kind != EventKind.deal) continue;
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
      if (dec.turn.hand != hand || !dec.turn.isPlay || dec.removal || e.kind != EventKind.play) continue;
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
  /// (_keysNameTheDraw in client.dart), or null: a person's name none,
  /// or a draw the hand carried that holds every bot seat; a held
  /// seat's name the draw the hand was sealed to, and come from the
  /// juror that draw names for the seat.
  String? keysNameTheDraw(TableEvent e, int seat, int hand) {
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

  /// Who said each held seat's keys, by hand: the seat's own juror from
  /// then on, as the table reads it (_asKeyed in client.dart).
  final keyedBy = <int, Map<int, PublicKey>>{};
  for (final d in record) {
    try {
      final e = d.event;
      if (d.removal || e.kind != EventKind.deal || e.round != 0 || humans.contains(e.author)) continue;
      keyedBy.putIfAbsent(d.turn.hand, () => {})[e.seat] = e.author;
    } catch (_) {}
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
      if (e.kind != EventKind.deal || record[i].removal || e.round != 4) continue;
      try {
        pending[e.seat] = Uint8List.fromList(base64.decode(e.body['secret'] as String));
        final known = e.body['known'];
        if (known is Map) {
          for (final k in known.entries) {
            pending[int.parse(k.key as String)] = Uint8List.fromList(base64.decode(k.value as String));
          }
        }
      } catch (_) {}
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
      try {
        if (r.kind != EventKind.release || r.hand != game.handNumber) continue;
        final about = r.about;
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
      } catch (_) {}
    }
  }

  /// Whether a decision carries: a strict majority of [among], the set
  /// the peer measured against — which must be a legitimate one, every
  /// human who sat down less some of the removals made by [turn], never
  /// fewer than that.
  bool carried(Set<PublicKey> witnesses, TurnId turn, Set<PublicKey> among) {
    if (among.isEmpty || !humans.containsAll(among)) return false;
    if (!among.containsAll(floorAt(turn))) return false;
    return witnesses.intersection(among).length >= among.length ~/ 2 + 1;
  }

  for (final d in juries) {
    final e = d.event;
    if (!d.jury || e.kind != EventKind.jury) return fail('a jury that is not a jury proposal');
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
    if (expected.length != drawn.length || Iterable.generate(drawn.length).any((i) => expected[i] != drawn[i])) {
      return fail('a jury for hand ${e.hand} that is not the draw its snapshot gives');
    }
    if (!carried(d.witnesses, d.turn, d.among)) {
      return fail('a jury for hand ${e.hand} without a majority behind it (${d.witnesses.length} of ${d.among.length})');
    }
    jurors.putIfAbsent(e.hand, () => {}).addAll(drawn);
  }

  /// Whether [d] is carried by a verdict: a juror of the hand ruled
  /// for exactly this event at exactly this turn.
  bool byVerdict(Decision d) {
    final v = d.verdict;
    if (v == null || v.kind != EventKind.verdict) return false;
    if (!jurorsAt(d.turn.hand).contains(v.author)) return false;
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
      replay?._played(game.handNumber, seat, card);
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
        replay?._ended(game);
        game.nextHand();
      }
    }
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
      if (e.kind == EventKind.ended) {
        if (!humans.contains(e.author)) return 'the game ended by someone not at the table';
        if (e.turn != d.turn) return 'the game ended at ${d.turn} by a claim made at ${e.turn}';
        if (!carried(d.witnesses, d.turn, d.among)) {
          return 'the game ended at ${d.turn} without a majority behind it (${d.witnesses.length} of ${d.among.length})';
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
        if (e.kind != EventKind.escrow) continue;
        if (!heldAt(d.turn.hand).containsKey(seat)) return 'an escrow of seat $seat, which no juror held';
        if (escrowedAt[d.turn.hand]?.contains(seat) ?? false) return 'seat $seat given to the escrow twice in hand ${d.turn.hand}';
        if (!humans.contains(e.author)) return 'an escrow of seat $seat claimed by someone not at the table';
        if (!carried(d.witnesses, d.turn, d.among) && !byVerdict(d)) {
          return 'an escrow of seat $seat at ${d.turn} without a majority behind it (${d.witnesses.length} of ${d.among.length})';
        }
        escrowedAt.putIfAbsent(d.turn.hand, () => {}).add(seat);
        if (d.turn.isDeal) escrowedInDeal.putIfAbsent(d.turn.hand, () => {}).add(seat);
        if (d.turn.hand == game.handNumber) deal?.seatLeft(seat);
        continue;
      }
      if (e.kind == EventKind.escrow) return 'an escrow of seat $seat, which is a person\'s';
      if (e.kind == EventKind.leave) {
        // The leaver's own word, carried as a boot is: a majority of the
        // people at its turn, the leaver's signature its own vote
        // (_settleLeave in client.dart).
        if (e.author != holder.key) return 'a leave signed by someone else';
        if (e.turn != d.turn) return 'a leave recorded at ${d.turn}, said at ${e.turn}';
        if (!carried(d.witnesses, d.turn, d.among)) {
          return 'a leave of seat $seat at ${d.turn} without a majority behind it (${d.witnesses.length} of ${d.among.length})';
        }
      } else {
        final backers = Set.of(d.witnesses)..remove(holder.key);
        if (!carried(backers, d.turn, d.among) && !byVerdict(d)) {
          return 'a ${e.kind.name} of seat $seat at ${d.turn} without a majority behind it '
              '(${backers.length} of ${d.among.length})';
        }
      }
      removedAt[holder.key] = d.turn;
      holders[seat] = BotSeat(spec.replacementFor(seat));
      deal?.seatLeft(seat);
    }
    return null;
  }

  /// The next decision, which must be a human's action at [turn] by
  /// the key holding [seat], carried; or the reason it is not.
  (Decision?, String?) takeAction(TurnId turn, int seat, EventKind kind, {String? at}) {
    if (index >= record.length) return (null, allowPartial ? null : 'the record ends with seat $seat to ${kind.name}');
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
      if (e.kind != EventKind.deal || e.round != 4 || e.seat != seat) return fail('expected an audit by seat $seat, saw ${e.kind.name}');
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
        if (ended && allowPartial) return partial();
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

  var incomplete = false;

  while (game.phase != Phase.gameOver) {
    final why = takeRemovals();
    if (why != null) return fail(why);
    if (endedBy != null) return endedHere();
    if (game.phase == Phase.dealing) {
      final d = deal ?? startDeal();
      scanAudits(d);
      feedSecrets(d, all: false);
      final dealDone =
          !(index < record.length && record[index].turn.hand == game.handNumber && record[index].turn.isDeal) ||
          d.phase == DealPhase.dealt ||
          d.phase == DealPhase.audited;
      if (dealDone) {
        if (d.phase != DealPhase.dealt && d.phase != DealPhase.audited) {
          if (allowPartial && index >= record.length) return partial();
          // A hand given up in its deal: a bot seat's juror went with
          // a step of the seat still owed, and nobody else can take it
          // — the juror drew the key. The table gives the hand up
          // unscored and deals the next (_giveUpUndealtHand in
          // client.dart), with no audit, since the seat that stopped
          // it cannot be opened to show anything. So the record goes
          // on to a later hand with this one's deal short, and that
          // is a hand over, not a deal left unfinished
          // (docs/04-live-play.md, "When quorum is lost anyway").
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
            continue;
          }
          return fail('hand ${game.handNumber}: the deal is not complete (${d.phase.name})');
        }
        // A hand whose audits follow its deal with nothing in between
        // never began: nobody could lead it, so the table opened it to
        // find out why and gave it up (docs/03-fair-deal.md, and
        // _giveUpHand in client.dart). Two things make that legitimate,
        // and both are in the record: every seat's own signed word put
        // the lead card nowhere, and the deal those audits open shows
        // one of them holding it. What the record must not then contain
        // is the hand played on with every card in the open, and it
        // cannot: the audits are where the hand ends.
        final givenUp = nextIsAudit();
        // A newcomer's piece is released like any other, and one this
        // side could not place was taken for nobody's: a seat given to
        // the escrow, opened at the table from a topped-up juror's
        // piece and another, was never opened here (sealed chaos seed
        // 10, nine strangers).
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
          continue;
        }
        final leader = d.leader;
        if (leader == null) return fail('hand ${game.handNumber}: nobody declared the lead card');
        final hands = <List<Card>?>[];
        for (var s = 0; s < seatCount; s++) {
          final cards = d.dealtHandOf(s);
          if (cards == null && !allowPartial) return fail('hand ${game.handNumber}: seat $s\'s cards were never opened');
          if (cards == null) incomplete = true;
          hands.add(cards == null ? null : [for (final i in cards) Card.deck[i]]);
        }
        game.declareLeader(leader);
        game.deal(hands);
        continue;
      }
      // The next step owed: the first unsettled seat of the round the
      // deal is at, in the order the table opens them.
      final round = switch (d.phase) {
        DealPhase.keys => 0,
        DealPhase.shuffles => 1,
        DealPhase.tokens => 2,
        _ => 3,
      };
      if (index >= record.length) return allowPartial ? partial() : fail('the record ends mid-deal');
      final next = record[index];
      final e = next.event;
      if (e.kind != EventKind.deal || !next.turn.isDeal) return fail('hand ${game.handNumber}: expected a deal step, saw ${e.kind.name}');
      if (next.turn.dealRound != round || e.round != round) {
        return fail('hand ${game.handNumber}: a deal step of round ${e.round} where round $round is owed');
      }
      final seat = next.turn.dealSeat;
      final (dec, whyNot) = takeAction(next.turn, seat, EventKind.deal);
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
      continue;
    }
    if (game.phase == Phase.passing) {
      for (var s = 0; s < seatCount; s++) {
        // A bot seat a juror holds said its pass in the record, like a
        // person's; only one nobody holds is recomputed here.
        if (holders[s] is BotSeat && heldAt(game.handNumber)[s] == null && !game.hasPassed(s)) {
          final whyNot = botActs(s, passing: true);
          if (whyNot != null) return allowPartial ? partial() : fail(whyNot);
        }
      }
      if (game.phase != Phase.passing) continue;
      if (index >= record.length) return allowPartial ? partial() : fail('the record ends mid-pass');
      final d = record[index++];
      final e = d.event;
      if (e.kind != EventKind.pass) return fail('expected a pass, saw ${e.kind.name}');
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
        continue;
      }
      try {
        game.setPass(e.seat, [for (final c in e.body['cards'] as List) Card.parse(c as String)]);
      } catch (_) {
        return fail('an illegal pass by seat ${e.seat}');
      }
      continue;
    }
    if (game.phase == Phase.handOver) {
      // A sealed hand ends with its audits, one per person still
      // seated; then the next deal.
      final v = takeAudits();
      if (v != null) return v;
      // Every card open now: what each seat was dealt, and held after
      // the pass, for whoever is looking at the game afterwards.
      replay?._ended(game, deal);
      game.nextHand();
      deal = null;
      continue;
    }
    final seat = game.currentSeat!;
    if (holders[seat] is BotSeat && heldAt(game.handNumber)[seat] == null) {
      final whyNot = botActs(seat, passing: false);
      if (whyNot != null) return allowPartial ? partial() : fail(whyNot);
      sweep();
      continue;
    }
    if (index >= record.length) return allowPartial ? partial() : fail('the record ends with seat $seat to play');
    final d = record[index++];
    final e = d.event;
    if (e.kind != EventKind.play) return fail('expected a play, saw ${e.kind.name}');
    if (!mayAct(seat, e.author, d.turn.hand) || e.seat != seat) {
      return fail('a play by a key that did not hold seat $seat');
    }
    final turn = TurnId.play(game.handNumber, playIndex());
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
    // price of the hand being hidden (docs/04-live-play.md).
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
    replay?._played(game.handNumber, seat, card);
    game.play(seat, card);
    played.add(card);
    sweep();
  }
  if (deal != null) {
    // The last hand is audited too — after whatever the record removes
    // at its audits, which comes first at their position as at every
    // hand's. Taken straight to the audits, a claim for the escrow at
    // one of them stopped the replay before any audit, and the hand's
    // audits and that claim went unchecked.
    final why = takeRemovals();
    if (why != null) return fail(why);
    if (endedBy != null) return endedHere();
    final v = takeAudits();
    if (v != null) return v;
    replay?._ended(game, deal);
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


/// A game as the verifier replayed it, for looking at afterwards: hand
/// by hand, what each seat was dealt and held after the pass, every
/// card in the order played, and the scores. Filled only as far as the
/// record checks out — a record that fails has no replay worth showing.
class TableReplay {
  final List<TableReplayHand> hands = [];

  TableReplayHand _hand(int number) {
    while (hands.length <= number) {
      hands.add(TableReplayHand._(hands.length));
    }
    return hands[number];
  }

  void _played(int hand, int seat, Card card) => _hand(hand).plays.add((seat: seat, card: card));

  void _ended(HeartsGame game, [DealSession? deal]) {
    final h = _hand(game.handNumber)
      ..scores = List.of(game.handScores)
      ..totals = List.of(game.totals);
    if (deal == null) return;
    List<Card>? cards(List<int>? indices) => indices == null ? null : ([for (final i in indices) Card.deck[i]]..sort());
    final dealt = [for (var s = 0; s < seatCount; s++) cards(deal.dealtHandOf(s))];
    if (dealt.every((c) => c != null)) h.dealt = [for (final c in dealt) c!];
  }
}

class TableReplayHand {
  TableReplayHand._(this.number);

  final int number;

  /// Each seat's thirteen as dealt; null where the deal never opened
  /// them (a game that ended mid-hand).
  List<List<Card>>? dealt;

  /// Each seat's thirteen once the pass was made: what it played, since
  /// a hand is played out to the last card. Null for a hand cut short.
  List<List<Card>>? get held => plays.length < seatCount * 13
      ? null
      : [
          for (var s = 0; s < seatCount; s++) [for (final p in plays) if (p.seat == s) p.card]..sort(),
        ];

  /// Every card in the order it was played.
  final List<({int seat, Card card})> plays = [];

  /// The hand's points per seat, and the running totals after it; empty
  /// for a hand the game ended in the middle of.
  List<int> scores = const [];
  List<int> totals = const [];

  /// The plays, four to a trick.
  List<List<({int seat, Card card})>> get tricks => [
        for (var i = 0; i < plays.length; i += seatCount) plays.sublist(i, min(i + seatCount, plays.length)),
      ];

  /// What [seat] passed: dealt and not held.
  List<Card> passedBy(int seat) {
    final held = this.held;
    return dealt == null || held == null ? const [] : [for (final c in dealt![seat]) if (!held[seat].contains(c)) c];
  }
}
