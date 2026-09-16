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
  });

  final bool ok;
  final String reason;

  /// Whether the record ran to the end of the game. A partial record can
  /// still be [ok]: everything in it checked.
  final bool complete;

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
}) {
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

  DealSession startDeal() => deal = DealSession(
    crypto!,
    tableId: spec.id,
    tableSeed: spec.seed,
    hand: game.handNumber,
    seats: [
      for (final h in holders)
        switch (h) {
          HumanSeat(:final key) => HumanDealSeat(key),
          BotSeat() => const BotDealSeat(),
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

  final jurors = <int, Set<PublicKey>>{};
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
      game.play(seat, card);
      played.add(card);
    }
    return null;
  }

  void sweep() {
    if (game.pendingTrick != null) game.collectTrick();
    if (game.phase == Phase.handOver) {
      played.clear();
      if (!spec.sealed) game.nextHand();
    }
  }

  /// Applies the departures recorded next, each checked against the
  /// participants at the turn it names.
  String? takeRemovals() {
    while (index < record.length && record[index].removal) {
      final d = record[index++];
      final e = d.event;
      final seat = e.seat;
      final holder = holders[seat];
      if (holder is! HumanSeat) continue;
      if (e.kind == EventKind.leave) {
        if (e.author != holder.key) return 'a leave signed by someone else';
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
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != e.author || e.seat != seat) {
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
    while (nextIsAudit()) {
      final dec = record[index++];
      final e = dec.event;
      final seat = dec.turn.auditSeat;
      final holder = holders[seat];
      if (e.kind != EventKind.deal || e.round != 4 || e.seat != seat) return fail('expected an audit by seat $seat, saw ${e.kind.name}');
      if (holder is! HumanSeat || holder.key != e.author) return fail('an audit by a key that did not hold seat $seat');
      if (!carried(dec.witnesses, dec.turn, dec.among) && !byVerdict(dec)) {
        return fail('an audit at ${dec.turn} by seat $seat without a majority behind it (${dec.witnesses.length} of ${dec.among.length})');
      }
      if (!d.acceptAudit(Map<String, Object?>.from(e.body))) {
        return fail('hand ${game.handNumber}: an audit by seat $seat that is not the secret behind its key');
      }
      final why = takeRemovals();
      if (why != null) return fail(why);
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

  var incomplete = false;

  while (game.phase != Phase.gameOver) {
    final why = takeRemovals();
    if (why != null) return fail(why);
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
        if (holders[s] is BotSeat && !game.hasPassed(s)) {
          final whyNot = botActs(s, passing: true);
          if (whyNot != null) return allowPartial ? partial() : fail(whyNot);
        }
      }
      if (game.phase != Phase.passing) continue;
      if (index >= record.length) return allowPartial ? partial() : fail('the record ends mid-pass');
      final d = record[index++];
      final e = d.event;
      if (e.kind != EventKind.pass) return fail('expected a pass, saw ${e.kind.name}');
      final holder = holders[e.seat];
      if (holder is! HumanSeat || holder.key != e.author) return fail('a pass by a key that did not hold seat ${e.seat}');
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
      game.nextHand();
      deal = null;
      continue;
    }
    final seat = game.currentSeat!;
    if (holders[seat] is BotSeat) {
      final whyNot = botActs(seat, passing: false);
      if (whyNot != null) return allowPartial ? partial() : fail(whyNot);
      sweep();
      continue;
    }
    if (index >= record.length) return allowPartial ? partial() : fail('the record ends with seat $seat to play');
    final d = record[index++];
    final e = d.event;
    if (e.kind != EventKind.play) return fail('expected a play, saw ${e.kind.name}');
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != e.author || e.seat != seat) {
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
    game.play(seat, card);
    played.add(card);
    sweep();
  }
  if (deal != null) {
    // The last hand is audited too.
    final v = takeAudits();
    if (v != null) return v;
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
