/// The sealed deal (docs/explanation/fair-deal.md): each hand's deal
/// session, the draw it is sealed to, this side's own steps of it, and
/// the worker that makes its slow calls.
///
/// The cards of a sealed table come from a deal every seat shuffles
/// with a proof, and each person's cards are theirs alone to see. Here
/// the deal is turns like any other. At the hand's start the four keys
/// turns open at once; when they are settled the shuffle turns open
/// one at a time in seat order; when the deck is done the tokens turns
/// open at once, then the declarations; then the engine is dealt what
/// this side can see and the hand goes on as at any table. A bot's
/// turn is public work the session already did. A person's turn
/// settles by their action, which the session verified on arrival, or
/// by their removal, after which the seat's secret is awaited from the
/// escrow (client.dart).
///
/// What the deal holds of its own is here. It reads the table through
/// [DealTable], which the table's client gives it. Unlike the juror and
/// the escrow it moves the table as well as speaking at it: it opens
/// the deal's turns, deals the engine, and gives up a hand that cannot
/// be played, each through [DealTable] or the engine itself.
library;

import 'dart:async';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import 'clock.dart';
import 'conduct.dart';
import 'events.dart';
import 'journal.dart';
import 'juror_role.dart' show TurnVotes;
import 'jury.dart';
import 'model.dart';
import 'signing.dart';
import 'spec.dart';

/// What the deal reads of the table it deals, and how it moves it.
abstract interface class DealTable {
  /// The game is over, and at a sealed table its last hand audited.
  bool get done;

  /// Whether this side still says its own steps at [turn]: every turn
  /// until it leaves, and after that the turns before the place its
  /// leave was made at, which are still its own (TableClient.leave).
  bool ownsTurn(TurnId turn);

  /// Whether this side has stopped following the table.
  bool get closed;

  /// This side's seat, where it sat down, and whether it still holds
  /// it.
  int? get mySeat;
  bool get amSeated;

  SeatHolder holderOf(int seat);
  bool get hasBotSeats;

  /// Whether the table draws juries at all, and whether it has found
  /// nobody online to draw one from.
  bool get drawsJuries;
  bool get needsJuror;

  /// Whether a hand is held back for want of a jury big enough to hold
  /// its bot seats.
  bool get shortOfJurors;
  set shortOfJurors(bool short);

  Pause? get pause;
  set pause(Pause? pause);

  /// What this seat says where it could say something else.
  SeatConduct get conduct;

  /// The turn's votes, or null for a turn not open here.
  TurnVotes? votesAt(TurnId turn);

  /// When [turn] opened here.
  int openedAt(TurnId turn);

  /// Where [person] was removed, or null while they have not been.
  TurnId? removedAt(PublicKey person);

  /// Whether [turn] settled by a removal.
  bool settledByRemoval(TurnId turn);

  /// The jury proposals drawn for [hand], in the juries' own order
  /// (compareJuries, client.dart).
  List<TableEvent> juryDraws(int hand);

  /// The jurors of the draw [id] at [hand], or null where it has not
  /// carried here.
  List<PublicKey>? juryById(String? id, int hand);

  /// Every juror of [hand] as this side has them.
  Set<PublicKey> jurorsOf(int hand);

  /// Whether [hand] was over before the summons that brought this side
  /// here.
  bool beforeSummons(int hand);

  /// The jury this side was summoned into for [hand], or null where it
  /// serves none.
  List<PublicKey>? summonedInto(int hand);

  /// [hand]'s first jury as a summons gave it, where one has said so
  /// (JurorRole.firstSummons).
  ({String juryId, List<PublicKey> jurors})? firstSummons(int hand);

  /// The escrow's custodians at [hand], in its own order; and the list
  /// grown as the record now says (EscrowCustody.applyGrowth).
  List<PublicKey> custodians(int hand);
  void growCustodians(int hand);

  /// Whether [turn] is the audit of a seat the record has given to the
  /// escrow, whose juror does not say it.
  bool escrowedAudit(TurnId turn, int seat);

  /// Opens [turn], [seat]'s, where it is not open already.
  void openTurn(TurnId turn, int seat);

  /// The hand's cards are in: open the pass, or the first play.
  void openPlay();

  /// Every open turn of [seat] offered to the bot here.
  void takeUpSeat(int seat);

  /// The hand is over as an unplayed one, ended [how]; the next is
  /// dealt in its place.
  void abandonHand(HandState how);

  /// Forgets the turns that waited on a departed seat's secret: a new
  /// deal has none.
  void clearStalled();

  /// Moves every turn that waited on a departed seat's secret and now
  /// can.
  void resumeStalled();

  /// Every secret the escrow still holds sealed to the jury, said in
  /// the open.
  void sayOpenReleases();

  /// Boots whoever the deal has shown to have lied ([DealDriver.liars]).
  void bootLiars();

  /// Looks again at what was kept for later.
  void drainFuture();

  void leave();
  void close();

  /// Says an event of this side's, as the table says one.
  void emit(EventKind kind, Map<String, Object?> body);

  /// A line a hand, for whatever this side is declining to do.
  void sayOnce(int hand, String line);

  void notify();
  void trace(String line);
}

class DealDriver {
  DealDriver({
    required this.spec,
    required this.signer,
    required this.clock,
    required this.game,
    required this.table,
    this.crypto,
    this.dealWorker,
    this.journal,
    this.random,
  });

  final TableSpec spec;
  final Signer signer;
  final Clock clock;

  /// The engine this deals: the cards, the leader and the passes.
  final HeartsGame game;
  final DealTable table;

  /// The deal's primitives, the worker that makes its slow calls, the
  /// journal that keeps this side's secrets, and where its secrets and
  /// seeds come from: as the table's client was given them
  /// (client.dart, which says what each is for).
  final DealCrypto? crypto;
  final DealWorker? dealWorker;
  final TableJournal? journal;
  final Random? random;

  // ---- each hand's deal -----------------------------------------------

  /// This hand's deal, at a sealed table.
  DealSession? _deal;

  /// The current hand's deal, and any hand's so far (TableClient.deal,
  /// TableClient.dealOf).
  DealSession? get deal => _deal;
  DealSession? dealOf(int hand) => _dealsByHand[hand];
  final Map<int, DealSession> _dealsByHand = {};

  /// The deal is built once, and a bot seat's holder is fixed in it,
  /// so a table that holds bots with the jury waits for the jury
  /// before building it. The jury is proposed as the hand opens and
  /// settles a moment later, and a table with bot seats waits past
  /// that for a jury big enough to hold them — the call for a backup
  /// juror is what answers on a quiet night
  /// (docs/explanation/live-play.md).
  ///
  /// It waits for as long as that takes. A bot's hand dealt in the
  /// open is the table's to see, and at two people and two bots that
  /// is the other person's hand by subtraction; a rated table played
  /// that way is one a person can win by reading. So there is no
  /// point past which it goes ahead without: a table nobody can hold
  /// waits, and says so.
  void startWhenReady() {
    // A deal for *this* hand: _deal still holds the last one until the
    // new one replaces it, and testing it for null strands every hand
    // after the first.
    if (!spec.sealed || table.done) return;
    if (_deal != null && _deal!.hand == game.handNumber) return;
    if (table.hasBotSeats) {
      // A jury that holds every bot seat — which covers waiting for a
      // jury at all, since a hand with no jury holds nothing.
      final held = botHolders(game.handNumber);
      if (!_everyBotHeld(held)) {
        if (!table.shortOfJurors) {
          table.shortOfJurors = true;
          table.trace('hand ${game.handNumber}: waiting for a jury that can hold the bot seats');
          table.notify();
        }
        return;
      }
      if (table.shortOfJurors) {
        table.shortOfJurors = false;
        table.notify();
      }
    }
    _startDeal();
  }

  bool _everyBotHeld(Map<int, PublicKey> held) {
    for (final s in botSeatsAt(game.handNumber)) {
      if (!held.containsKey(s)) return false;
    }
    return true;
  }

  void _startDeal({bool drain = true}) {
    final c = _prepared ?? crypto!;
    final held = botHolders(game.handNumber);
    _heldByHand[game.handNumber] = held;
    final from = _sealedTo.containsKey(game.handNumber) ? _sealedTo[game.handNumber] : _provisionalDraw(game.handNumber).id;
    if (from != null) _heldFrom[game.handNumber] = from;
    // The deal's notion of this side's seat is not the table's: a juror
    // sits at no seat here and still acts for the bot seat it holds.
    final me = table.amSeated
        ? table.mySeat
        : table.beforeSummons(game.handNumber)
            ? null
            : _seatHeldHere(held);
    final before = _dealsByHand[game.handNumber];
    _deal = DealSession(
      c,
      tableId: spec.id,
      tableSeed: spec.seed,
      hand: game.handNumber,
      seats: [
        for (var s = 0; s < seatCount; s++)
          switch (table.holderOf(s)) {
            HumanSeat(:final key) => HumanDealSeat(key),
            // A bot seat a juror holds carries that juror's key and is
            // a seat that acts for itself; one nobody holds carries
            // none and stays everyone's to compute.
            BotSeat() => BotDealSeat(key: held[s]),
          },
      ],
      leadCard: twoOfClubs.index,
      mySeat: me,
      // Built again for the same hand and the same seat, the deal goes on
      // with the secret this side's keys were made from ([refixHolders]).
      // A new one would put this side's own key apart from the one on the
      // record — a session keeps its own seat's keys and no other — and
      // nothing shuffled from the record's could be checked here
      // (sealed_to_draw_test.dart). A client built again after a reload
      // has the secret its keys for the hand were made from in its
      // journal, kept for this.
      mySecret: before != null && before.mySeat == me ? before.mySecret : (me != null && me == table.mySeat ? journal?.secretFor(game.handNumber) : null),
      myKey: signer.publicKey,
      wrap: signer.sharedSecretWith,
      random: random,
    )..log = (l) => table.trace('deal: $l');
    _dealsByHand[game.handNumber] = _deal!;
    final kept = _deal!.mySecret;
    if (table.amSeated && me == table.mySeat && kept != null) journal?.keep(game.handNumber, kept);
    // Which juror holds which bot seat, said once as the deal is
    // built. It is no secret — the assignment is the hand's first
    // jury read in its drawn order, so every side works out the same
    // one — and it is the fact every other line about a bot seat
    // refers to: the seat going to the escrow, the pieces coming in,
    // the seat played on by somebody else.
    if (held.isNotEmpty) {
      table.trace('hand ${game.handNumber}: the jury holds bot '
          '${held.entries.map((e) => 'seat ${e.key} (${e.value.substring(0, 8)})').join(', ')}');
    }
    table.clearStalled();
    for (var s = 0; s < seatCount; s++) {
      table.openTurn(TurnId.deal(game.handNumber, 0, s), s);
    }
    // And whatever came for those turns before there was a deal to
    // put it in. A hand's first four steps go out the moment the
    // table has a jury, and a juror summoned a moment later — or any
    // peer whose own deal waited on a draw it had not heard — has
    // them in hand before it has built the session that checks them:
    // kept, because a turn that is not open yet is not a turn the
    // event is wrong for (client.dart, _defer). They are drained here:
    // the other drains run when a turn settles, when a jury changes and
    // when the assignment is fixed again, and the steps this side needs
    // to settle its first turn are exactly these.
    //
    // Not yet when the deal is built again ([refixHolders]): the
    // steps that already settled go back in first.
    if (!drain) return;
    // A hand with nobody at the table to key it is sealed to no draw at
    // once ([checkSealed]); any other waits for its first person's keys.
    checkSealed(game.handNumber);
    table.drainFuture();
    table.bootLiars();
    act();
  }

  // ---- the draw it is sealed to, and who holds a bot seat -------------

  /// Each hand's bot-seat holders, fixed once the hand's deal is built:
  /// a bot seat's holder is in that deal, and a jury redrawn mid-hand
  /// would otherwise move the seat out from under it — the juror still
  /// saying its steps while everyone, itself included, stopped
  /// accepting them for it.
  final Map<int, Map<int, PublicKey>> _heldByHand = {};

  /// And which jury each fixed assignment was read from, so that one
  /// fixed before the hand's first jury had arrived can be told from
  /// one fixed after ([refixHolders]).
  final Map<int, String> _heldFrom = {};

  /// The draw each hand's deal is sealed to, as the record says it: the
  /// one named by the keys of the first person at the table whose keys
  /// for the hand have settled ([checkSealed]). Null for keys that
  /// name none, the hand's bot seats dealt in the open. Absent until
  /// the record has said.
  final Map<int, String?> _sealedTo = {};

  /// The draw [hand]'s deal was sealed to, or until the record says,
  /// the one read here (TableClient.sealedTo).
  String? sealedTo(int hand) => _sealedTo.containsKey(hand) ? _sealedTo[hand] : _heldFrom[hand];

  /// Whether the record has said which draw [hand]'s deal is sealed to
  /// ([checkSealed]).
  bool sealedOnRecord(int hand) => _sealedTo.containsKey(hand);

  /// Who keyed each seat at `hand`, by the event that settled its
  /// first deal round.
  final Map<int, Map<int, PublicKey>> _keyedBy = {};

  /// [seat]'s keys at [hand] carried, made by [by].
  void keyed(int hand, int seat, PublicKey by) => _keyedBy.putIfAbsent(hand, () => {})[seat] = by;

  /// [_keyedBy] at [hand] (TableClient.keyedBy).
  Map<int, PublicKey> keyedBy(int hand) => _keyedBy[hand] ?? const {};

  /// Which juror holds which bot seat at [hand]
  /// (TableClient.botHolders).
  Map<int, PublicKey> botHolders(int hand) {
    // Only at a sealed table. An unsealed one has no hidden hands to
    // keep from anybody, so a juror holding a bot seat there would
    // protect nothing and only take the seat away from the peers that
    // work its moves out between them.
    if (!spec.sealed) return const {};
    // The record's, once it has said which draw the deal is sealed to.
    if (_sealedTo.containsKey(hand)) return _asKeyed(hand, _heldAtSeal(hand));
    final fixed = _heldByHand[hand];
    if (fixed != null) return _asKeyed(hand, Map.of(fixed));
    return _asKeyed(hand, assignBots(_provisionalDraw(hand).jurors, botSeatsAt(hand)));
  }

  /// The holders the draw the record seals [hand] to names.
  Map<int, PublicKey> _heldAtSeal(int hand) {
    final jury = table.juryById(_sealedTo[hand], hand);
    return jury == null ? {} : assignBots(jury, botSeatsAt(hand));
  }

  /// Whether [jury] can hold every one of [bots]: a draw of fewer than
  /// [juryToHoldBots] holds none.
  bool _holdsAll(List<PublicKey> jury, List<int> bots) => assignBots(jury, bots).length == bots.length;

  /// The draw a hand's bot seats are read from here until the record
  /// says which one its deal is sealed to ([_sealedTo]).
  ///
  /// The first drawn for the hand that can hold every bot seat, in the
  /// order every side reads them ([DealTable.juryDraws]) rather than the
  /// order they settled here — [DealTable.jurorsOf] is a set whose
  /// iteration order follows this peer's own history, and two peers that
  /// saw the same juries in a different order would hand the same seat
  /// to different jurors. Not a draw that holds nothing: a small redraw proposed from
  /// an earlier place, read first, would put a hand's bot seats in the
  /// open at one side while the others dealt them to a jury.
  ///
  /// Or the hand's first jury as the summons gave it, where the event
  /// that drew it has not been carried here yet
  /// ([DealTable.firstSummons]). Only that one: a juror topped up
  /// mid-hand is summoned with the jury as it stands then, and that
  /// list names a different holder for each seat.
  ({String? id, List<PublicKey> jurors}) _provisionalDraw(int hand) {
    final bots = botSeatsAt(hand);
    final drawn = table.juryDraws(hand);
    for (final d in drawn) {
      if (_holdsAll(d.jurors, bots)) return (id: d.id, jurors: d.jurors);
    }
    if (drawn.isNotEmpty) return (id: drawn.first.id, jurors: drawn.first.jurors);
    final summoned = table.firstSummons(hand);
    return (id: summoned?.juryId, jurors: summoned?.jurors ?? const <PublicKey>[]);
  }

  /// The jury [hand]'s deal was sealed to: the record's, once it has
  /// said ([checkSealed]); until then the one this side reads
  /// ([_provisionalDraw]). What the escrow's custodians start from, and
  /// who counts as drawn since. Not simply the first draw by order: the
  /// record may seal the hand to one proposed from a later place.
  List<PublicKey> dealtTo(int hand) {
    if (_sealedTo.containsKey(hand)) return table.juryById(_sealedTo[hand], hand) ?? const [];
    return _provisionalDraw(hand).jurors;
  }

  /// The draw this side's keys for [hand] name: the record's where it
  /// has said, and otherwise the one its deal was built against, if
  /// that holds the bot seats; none where it holds nothing.
  String? _drawNamed(int hand) {
    if (_sealedTo.containsKey(hand)) return _sealedTo[hand];
    final held = _heldByHand[hand];
    return held != null && held.isNotEmpty ? _heldFrom[hand] : null;
  }

  /// Whether the record now says which draw [hand]'s deal is sealed to,
  /// and the deal made to follow it if so.
  ///
  /// Each side reads the draw for itself, from the juries it has heard,
  /// and a draw proposed from an earlier place can arrive after one
  /// proposed from a later place, so the sides can read different
  /// draws; the record settles it. Every seat's
  /// keys name the draw they were sealed to, and the draw named by the
  /// first person whose keys settle — lowest seat first, passing over a
  /// person whose turn went to a removal or to the bot their seat
  /// turned into — is the hand's. A held seat's keys are taken only
  /// once that has settled, naming the same draw, from the juror it
  /// names for the seat ([keysNameTheDraw]); its juror waits for it
  /// before making them ([act]).
  void checkSealed(int hand) {
    if (!spec.sealed || _sealedTo.containsKey(hand)) return;
    final bots = botSeatsAt(hand);
    String? named;
    int? by;
    for (var s = 0; s < seatCount; s++) {
      if (bots.contains(s)) continue;
      final turn = TurnId.deal(hand, 0, s);
      final race = table.votesAt(turn);
      if (race == null || !race.settled) return;
      final e = race.action;
      if (table.settledByRemoval(turn) || e == null) continue;
      final jury = e.body['jury'];
      // A draw not carried here yet: _settleJury (client.dart) looks again.
      if (jury is String && table.juryById(jury, hand) == null) return;
      named = jury is String ? jury : null;
      by = s;
      break;
    }
    // With no person left to say it — every seat a bot's when the hand
    // began, a leaver's client looking on — there is no jury to seal to.
    _sealedTo[hand] = named;
    table.trace('hand $hand: sealed to ${named != null ? 'the draw ${named.substring(0, 8)}' : 'no draw, its bot seats in the open'}'
        '${by != null ? ', by seat $by\'s keys' : ', with nobody at the table to key it'}');
    refixHolders(hand);
    // A bot seat's keys waited for this (client.dart, _botActs).
    for (final s in bots) {
      table.takeUpSeat(s);
    }
    table.drainFuture();
    act();
    table.notify();
  }

  /// Whether a seat's keys name a draw this side can take them against:
  /// a person's, none or a draw carried here that holds every bot seat;
  /// a held seat's, the draw the record has sealed the hand to, made by
  /// the juror that draw names for the seat ([checkSealed]).
  bool keysNameTheDraw(TableEvent e, int seat) {
    final hand = e.turn.hand;
    final named = e.body['jury'];
    if (named != null && named is! String) return false;
    final bots = botSeatsAt(hand);
    if (!bots.contains(seat)) {
      if (named == null) return true;
      final jury = table.juryById(named as String, hand);
      return jury != null && _holdsAll(jury, bots);
    }
    if (!_sealedTo.containsKey(hand) || named != _sealedTo[hand]) return false;
    return _heldAtSeal(hand)[seat] == e.author;
  }

  /// The bot seats a jury holds at [hand]: the ones that were already
  /// bots when the hand began.
  ///
  /// Read from the record rather than from the seat list as it stands
  /// here, because while a departure is in flight those are not the
  /// same thing. A person leaving turns their seat into a bot, and
  /// [assignBots] hands the bot seats out in order — so one seat more
  /// than another peer has shifts every juror onto a different seat,
  /// and each then refuses what the others say for theirs, and the
  /// hand stops at a seat whose keys are nobody's to make.
  ///
  /// The hand a person leaves in is not the jury's to hold in any
  /// case. That seat's cards are opened from the escrow in the clear,
  /// because the hand they open was that person's own and the table
  /// is entitled to check it, and from then on the seat is everyone's
  /// to play (client.dart, _botActsHere; `_deal.gone`). It becomes a
  /// bot seat the jury holds at the hand after, when it is dealt cards
  /// nobody has seen.
  List<int> botSeatsAt(int hand) {
    final out = <int>[];
    for (var s = 0; s < seatCount; s++) {
      if (table.holderOf(s) is! BotSeat) continue;
      final was = spec.seats[s];
      if (was is HumanSeat) {
        // Where the leaver stood, not where this peer noticed: a
        // removal is placed at a turn, and every side reads the same
        // hand from it.
        final at = table.removedAt(was.key);
        if (at == null || at.hand >= hand) continue;
      }
      out.add(s);
    }
    return out;
  }

  /// The draw, corrected by the record wherever the record has
  /// spoken. A seat's holder is read from the hand's first jury only
  /// until that seat's keys settle; from then on it is whoever made
  /// them, because that is the one thing every side agrees about.
  ///
  /// The draw and the record can differ. A juror summoned into a
  /// redraw hears the redraw before it is carried the draw that came
  /// first, and reads itself into a seat that is somebody else's; the
  /// hand's own keys then settle on the seat's real holder and the
  /// draw it read is simply wrong. Left to stand, that peer would watch
  /// the wrong juror for silence and give up a seat nobody had lost.
  Map<int, PublicKey> _asKeyed(int hand, Map<int, PublicKey> drawn) {
    final said = _keyedBy[hand];
    if (said == null) return drawn;
    for (final e in said.entries) {
      if (drawn.containsKey(e.key)) drawn[e.key] = e.value;
    }
    return drawn;
  }

  /// The assignment against what the record now says it should be.
  /// Both of its two inputs can arrive after it was fixed:
  ///
  /// - **The hand's first jury.** A juror carried the record hears the
  ///   redraw that summoned it before the draw that came first, and
  ///   any peer can hear two juries out of order.
  /// - **Which seats are bots.** A person leaving turns their seat
  ///   into one, and a peer that has not heard the leave counts a seat
  ///   fewer ([botSeatsAt]). The leave decides a hand the assignment
  ///   is read for, so one arriving late moves it.
  ///
  /// Fixed again, and the deal built again with it — and the steps
  /// that already settled fed into the new session from the races
  /// that settled them, so that rebuilding costs nothing already
  /// agreed.
  void refixHolders(int hand) {
    final standing = _heldByHand[hand];
    if (standing == null) return;
    final from = _heldFrom[hand];
    final sealed = _sealedTo.containsKey(hand);
    // Short of the record's word, a deal dealt with its bots in the
    // open stays that way: it went ahead for want of a jury, and one
    // arriving later does not reach back into it.
    if (!sealed && from == null) return;
    final draw = sealed
        ? (id: _sealedTo[hand], jurors: table.juryById(_sealedTo[hand], hand) ?? const <PublicKey>[])
        : _provisionalDraw(hand);
    if (!sealed && draw.jurors.isEmpty) return;
    // The draw against the one standing here. They agree almost always
    // — a juror fixes from its summons a second before the draw it was
    // summoned into is carried to it — and agreeing is not worth a
    // rebuild: the assignment is the same, so say the jury it came from
    // and leave the deal alone.
    final again = assignBots(draw.jurors, botSeatsAt(hand));
    final now = draw.id;
    if (standing.length == again.length && standing.entries.every((e) => again[e.key] == e.value)) {
      if (now != null) _heldFrom[hand] = now;
      return;
    }
    // Only a hand still in play here. A hand the table has left — given
    // up in its deal while a jury drawn for it was still being carried,
    // the escrow and the draw each a round trip, in either order — has
    // nothing left to deal, and its session is still the one standing
    // until the next hand's jury comes: rebuilt, it would deal the next
    // hand to this one's jury.
    final d = _deal;
    if (d == null || d.hand != hand || hand != game.handNumber) return;
    table.trace('hand $hand: ${sealed ? 'the record seals it to another draw than' : now == from ? 'a seat turned into a bot after' : 'its first jury came after'} '
        'the bot seats were fixed; they are dealt again');
    _heldByHand.remove(hand);
    _heldFrom.remove(hand);
    _startDeal(drain: false);
    // And the steps that settled against the assignment just
    // discarded are taken into the new session, in the order the deal
    // takes them. They are all still here — a settled race keeps the
    // event that settled it — so a rebuild loses nothing, and one
    // that skipped them would be a session missing a seat's keys,
    // unable to verify a single thing that came after and unable to
    // ask for any of it again.
    for (var r = 0; r < TurnId.dealRounds; r++) {
      for (var seat = 0; seat < seatCount; seat++) {
        final race = table.votesAt(TurnId.deal(hand, r, seat));
        final e = race?.action;
        if (race != null && race.settled && e != null) applyStep(e, seat);
      }
    }
    // With them back in, the deal may be further on than the turns
    // open here: a round whose steps had all settled opens the next.
    // And only then what was held back for it, taken against the whole
    // of the deal rather than the part rebuilt so far: the other way
    // round, a round could close with the deal still at its keys and
    // nothing to ask the deal to go on again.
    advance();
    // Anything refused against the old assignment is worth another
    // look now: it was kept rather than dropped for exactly this.
    table.drainFuture();
    act();
  }

  /// The bot seat this side holds at that assignment, if any.
  int? _seatHeldHere(Map<int, PublicKey> held) {
    for (final e in held.entries) {
      if (e.value == signer.publicKey) return e.key;
    }
    return null;
  }

  // ---- the deal's turns -----------------------------------------------

  bool _roundDone(int round) =>
      Iterable<int>.generate(seatCount).every((s) => table.votesAt(TurnId.deal(game.handNumber, round, s))?.settled == true);

  /// The deal round whose turns are open: the first not yet settled.
  int get currentRound {
    for (var r = 0; r < TurnId.dealRounds; r++) {
      if (!_roundDone(r)) return r;
    }
    return TurnId.dealRounds - 1;
  }

  /// Opens what the deal's progress allows, and deals the engine when
  /// it is done.
  void advance() {
    final d = _deal;
    if (d == null || game.phase != Phase.dealing) return;
    final h = game.handNumber;
    if (!_roundDone(0)) return;
    // Shuffles, one at a time, in seat order: a bot's or a departed
    // seat's is computed by all when it is next, a person's awaited.
    for (var s = 0; s < seatCount; s++) {
      final t = TurnId.deal(h, 1, s);
      if (table.votesAt(t)?.settled == true) continue;
      if (table.votesAt(t) == null && (d.hasShuffled(s) || table.holderOf(s) is BotSeat || d.nextShuffler == s)) table.openTurn(t, s);
      if (table.votesAt(t)?.settled != true) return;
    }
    if (d.deck == null) return;
    for (var s = 0; s < seatCount; s++) {
      table.openTurn(TurnId.deal(h, 2, s), s);
    }
    if (!_roundDone(2)) return;
    for (var s = 0; s < seatCount; s++) {
      table.openTurn(TurnId.deal(h, 3, s), s);
    }
    if (!_roundDone(3)) return;
    _dealt(d);
  }

  /// The deal is done: the engine gets what this side can see, and
  /// the hand begins — unless nobody declared the lead card.
  void _dealt(DealSession d) {
    if (game.phase != Phase.dealing) return;
    final leader = table.conduct.leader(d.leader);
    if (leader == null) {
      if (table.pause != Pause.waitingForLead) table.trace('nobody declared the lead card');
      table.pause = Pause.waitingForLead;
      if (d.leadDisclaimed && !d.awaitsAnySecret) {
        _openTheHand('every seat disclaims the lead card');
      }
      return;
    }
    game.declareLeader(leader);
    game.deal([
      for (var s = 0; s < seatCount; s++)
        switch (d.dealtHandOf(s)) {
          null => null,
          final cards => [for (final i in cards) Card.deck[i]],
        },
    ]);
    if (table.pause == Pause.waitingForLead) table.pause = null;
    table.trace('dealt hand ${game.handNumber}, seat $leader to lead');
    table.openPlay();
  }

  /// A hand nobody can finish, opened where it stands and then given
  /// up. Two things leave one (docs/explanation/fair-deal.md), and neither can
  /// be undone by waiting:
  ///
  /// - every seat says it holds the two of clubs nowhere, and one of
  ///   them was dealt it, so nobody can lead and no seat's word will
  ///   say which lied;
  /// - a seat sealed its pass to nothing and will not show what it
  ///   sent, so the seat it passed to can never see three of its own
  ///   cards, nor play them, and the table waits on a turn that cannot
  ///   come.
  ///
  /// So the audit is called here instead of at the end of the hand, and
  /// the hand moves to where its audit is ([_openingAudit], which is
  /// what the table's position reads: client.dart, _herePosition). When
  /// the audits are in, every card is open — which is also how a
  /// verifier can see for itself that the hand was past saving — and
  /// the hand is given up rather than played on, because a hand
  /// everyone can see is not a hand.
  void _openTheHand(String why) {
    if (_openingAudit || !spec.sealed || _deal == null) return;
    _openingAudit = true;
    table.trace('hand ${game.handNumber}: $why; opening it');
    for (var s = 0; s < seatCount; s++) {
      table.openTurn(TurnId.audit(game.handNumber, s), s);
    }
    table.sayOpenReleases();
    act();
    table.drainFuture();
  }

  /// Whether this hand is being opened rather than played
  /// ([_openTheHand]).
  bool get openingAudit => _openingAudit;
  bool _openingAudit = false;

  /// The deal is open and the hand is given up: nothing was passed and
  /// nothing was played, so nothing is scored, and the next hand is
  /// dealt in its place (docs/explanation/fair-deal.md), under a hand number of
  /// its own because that is where its turns live.
  ///
  /// Whoever was dealt the lead card and disclaimed it is marked here
  /// and removed at the first turn of theirs that opens
  /// ([DealTable.bootLiars]). It cannot be removed at the turn it lied
  /// at: that one settled long before the cards said so.
  void giveUpHand() {
    final d = _deal;
    // Whoever the open hand shows to have broken it: the seat dealt the
    // lead card that said it held it nowhere, and the seat whose seal
    // would not open.
    final blamed = <int>{if (d?.lied case final seat?) seat};
    for (final seat in blamed) {
      final holder = table.holderOf(seat);
      if (holder is HumanSeat) _liars.add(holder.key);
    }
    table.trace('hand ${game.handNumber} given up, opened${blamed.isEmpty ? '' : '; seat(s) $blamed broke it'}');
    _openingAudit = false;
    table.abandonHand(HandState.givenUp);
  }

  /// A hand whose deal cannot be finished, because a bot seat's juror
  /// has gone with a deal turn of that seat still open. Nobody can
  /// make that seat's keys or its shuffle: the holder drew the key, and
  /// where the keys never went out there is not even an escrow holding
  /// pieces of it. The hand is given up unscored and the next dealt in
  /// its place, to a jury drawn again without the one that went
  /// (docs/explanation/live-play.md).
  ///
  /// Without an audit, unlike the hand that is opened and given up. A
  /// hand stopped in its deal has nothing to show — nothing was passed
  /// and nothing was played — and the seat that stopped it cannot be
  /// opened to say so. The verifier takes an abandoned hand as a
  /// terminal state rather than an incomplete one.
  ///
  /// Follows from the record, and only from it: the escrow of a held
  /// seat that still owed a step of the deal (client.dart,
  /// _carryEscrow), which a side behind is carried to like any removal
  /// (_carryForward).
  void giveUpUndealtHand(int seat) {
    table.trace('hand ${game.handNumber}: seat $seat cannot finish its deal; the hand is given up undealt');
    table.abandonHand(HandState.abandoned);
  }

  /// The keys of seats this peer has proof against: each said it held
  /// the lead card nowhere and was dealt it.
  Set<PublicKey> get liars => _liars;
  final Set<PublicKey> _liars = {};

  /// Tells the engine who leads, from where the lead card sits now.
  void declareLead() {
    final leader = _deal?.leader;
    if (leader != null && (game.phase == Phase.passing || game.phase == Phase.dealing)) game.declareLeader(leader);
  }

  // ---- this side's steps, and the others' -----------------------------

  /// This seat's own steps, whenever one is due: keys once a jury is
  /// in force to escrow to (or there is none to wait for, or ten
  /// seconds have passed), the shuffle when next, the tokens when the
  /// deck is done, the declaration when its hand is open, the audit
  /// when the hand is over.
  void act() {
    final d = _deal;
    if (d == null || table.done) return;
    // The seat this side acts for in the deal: its own if it is a
    // player, or the bot seat it holds if it is a juror. A player that
    // has been removed acts for nothing.
    final h = game.handNumber;
    final me = d.mySeat;
    if (me == null || (table.mySeat != null && !table.amSeated)) {
      // A juror serving the hand that cannot see who holds its bot
      // seats, said once a hand. Most jurors hold nothing and that is
      // ordinary; a juror that can see no assignment at all is one
      // step from being the holder the table is waiting on, and from
      // the outside it looks exactly like a device that has stopped.
      if (table.mySeat == null && table.summonedInto(h) != null && botHolders(h).isEmpty && table.hasBotSeats) {
        table.sayOnce(h, 'serving, but no bot seat is held as far as this side can see; '
            'juries drawn for it ${table.juryDraws(h).length}, summoned into its first ${table.firstSummons(h) != null}');
      }
      return;
    }
    TurnId? open(TurnId t) {
      final r = table.votesAt(t);
      return r != null && !r.settled && r.action == null && table.ownsTurn(t) ? t : null;
    }

    final keys = open(TurnId.deal(h, 0, me));
    if (keys != null) {
      final jurors = table.jurorsOf(h);
      final waited = clock.nowMs - table.openedAt(keys);
      if (jurors.isNotEmpty || !table.drawsJuries || table.needsJuror || waited >= 10000) {
        // A juror holds a seat by the draw the record seals the hand
        // to, and makes no keys until the record has said which that is
        // ([checkSealed]): read for itself, the draw is wrong for any
        // juror that heard a redraw before the draw that came first,
        // and keys made for the wrong seat are a step that settles —
        // the first action at a turn stands.
        if (!table.amSeated && !_sealedTo.containsKey(h)) return;
        // A held seat's shares are indexed by their custodian's place in
        // the list its keys name, which the record then grows
        // ([DealTable.growCustodians]): every juror of the hand heard
        // of here, in the juries' own order. A person's escrow goes by
        // sides, in no order.
        d.custodians = table.amSeated ? (jurors.toList()..sort()) : table.custodians(h);
        _emitDeal(keys, 0, me, {...d.myKeys()!, 'jury': _drawNamed(h)});
      }
    }
    final shuffle = open(TurnId.deal(h, 1, me));
    bool made(int round) => _prepared == null || _workedOut(d.workToMake(round));
    if (shuffle != null && d.nextShuffler == me && made(1)) _emitDeal(shuffle, 1, me, d.myShuffle()!);
    final tokens = open(TurnId.deal(h, 2, me));
    if (tokens != null && d.deck != null && made(2)) _emitDeal(tokens, 2, me, d.myTokens()!);
    final declare = open(TurnId.deal(h, 3, me));
    if (declare != null) {
      final m = d.myDeclaration();
      if (m != null) _emitDeal(declare, 3, me, table.conduct.declaration(m));
    }
    final audit = open(TurnId.audit(h, me));
    if (audit != null && !table.escrowedAudit(audit, me) && (game.phase == Phase.handOver || game.phase == Phase.gameOver || _openingAudit)) {
      _emitDeal(audit, 4, me, d.myAudit()!);
    }
  }

  /// A deal step for the seat it is taken for — this side's own, or
  /// the bot seat a juror holds, which is not the same as its seat at
  /// the table because a juror has none.
  void _emitDeal(TurnId turn, int round, int seat, Map<String, Object?> m) =>
      table.emit(EventKind.deal, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'round': round, ...m});

  /// Every key ever proposed as a juror at this table: what a seat may
  /// escrow to.
  final Set<PublicKey> _everProposed = {};

  /// Takes [jurors] as proposed at this table; whether any is new.
  bool proposed(List<PublicKey> jurors) {
    final before = _everProposed.length;
    _everProposed.addAll(jurors);
    return _everProposed.length != before;
  }

  /// A step of the deal: the turn's round and seat, and the session's
  /// check of the step itself. Keys may only escrow to jurors this
  /// peer has seen proposed at this table: a seat naming a key nobody
  /// can reach would leave its hand unopenable when it left.
  bool validStep(TableEvent e, int seat) {
    final d = _deal;
    if (d == null) return false;
    final t = e.turn;
    final b = Map<String, Object?>.from(e.body);
    if (b['seat'] != seat) return false;
    if (t.isAudit) return e.round == 4 && t.auditSeat == seat && d.verifyAudit(b);
    if (!t.isDeal || t.dealRound != e.round || t.dealSeat != seat) return false;
    switch (e.round) {
      case 0:
        final custodians = [for (final k in b['custodians'] as List) k as String];
        if (!custodians.every(_everProposed.contains)) return false;
        if (!keysNameTheDraw(e, seat)) return false;
        return d.verifyKeys(b);
      case 1:
        return d.verifyShuffle(b);
      case 2:
        return d.verifyTokens(b);
      case 3:
        return d.verifyDeclaration(b);
    }
    return false;
  }

  /// Whether [event] can be checked here now: for a deal step another
  /// seat sent, whether its checks have been made at the worker
  /// ([DealSession.workToTake]); if not, they are on their way, and
  /// the caller keeps the event for the drain that follows them back.
  /// This side's own steps are not checked (client.dart, _valid).
  bool checkable(TableEvent event) {
    final d = _deal;
    if (event.kind != EventKind.deal || d == null || _prepared == null || event.author == signer.publicKey) return true;
    return _workedOut(d.workToTake(event.round, Map<String, Object?>.from(event.body)));
  }

  /// A settled deal step, applied. Verified on arrival; this side's
  /// own were made here.
  void applyStep(TableEvent e, int seat) {
    final d = _deal!;
    final b = Map<String, Object?>.from(e.body);
    final ok = switch (e.round) {
      0 => d.acceptKeys(b, verified: true),
      1 => d.acceptShuffle(b, verified: true),
      2 => d.acceptTokens(b, verified: true),
      3 => d.acceptDeclaration(b, verified: true),
      4 => d.acceptAudit(b, verified: true),
      _ => false,
    };
    if (!ok) table.trace('a deal step settled that the session would not take: $e');
    if (ok && e.round == 0) table.growCustodians(e.hand);
    if (e.round == 4 || d.gone.isNotEmpty) table.resumeStalled();
  }

  /// A settled pass at a sealed table: the positions move, and the
  /// engine learns the cards this side can see.
  void applyPass(DealSession d, int seat, TableEvent e) {
    final b = Map<String, Object?>.from(e.body);
    if (!d.acceptPass(b, verified: true)) table.trace('a pass settled that the deal would not take: $e');
    final positions = [for (final p in b['positions'] as List) p as int];
    final cards = <Card>[];
    for (final p in positions) {
      final c = d.openedCardAt(p);
      if (c == null) break;
      cards.add(Card.deck[c]);
    }
    declareLead();
    final to = (seat + game.passDirection.seatOffset) % seatCount;
    if (cards.length != positions.length && game.knowsHand(to)) {
      // Into a seat whose hand is seen here — a departed seat's, opened
      // from escrow — a pass has to open too, and this one has not yet.
      // A pass a seat could never open does not get this far: the
      // argument beside each seal is checked before the pass is taken
      // (docs/explanation/fair-deal.md). The engine waits rather than take a
      // hand it cannot fill.
      table.trace('a pass into seat $to, whose hand is seen here, that will not open here yet: $e');
      return;
    }
    game.setPass(seat, cards.length == positions.length ? cards : null);
  }

  // ---- the worker -----------------------------------------------------

  /// The session's primitives, answering the slow calls from what
  /// [dealWorker] made.
  late final PreparedDeal? _prepared = dealWorker == null || crypto == null ? null : PreparedDeal(crypto!);

  /// Why this device cannot deal, once its worker has failed for good
  /// (TableClient.cannotDeal); null while it can.
  String? get cannotDeal => _cannotDeal;
  String? _cannotDeal;

  /// The slow calls refused for want of an answer from the worker
  /// (TableClient.dealCallsRefused).
  int get callsRefused => _prepared?.refused ?? 0;

  /// What the deals here came to on their own and are waiting on
  /// ([DealSession.wanted]): the first deck, a departed seat's work.
  /// Sent at every change, since any change can be what set it off.
  void sendWanted() {
    if (_prepared == null) return;
    for (final d in _dealsByHand.values) {
      final wanted = d.wanted;
      if (wanted.isNotEmpty) _workedOut(wanted);
    }
  }

  /// Whether the slow calls in [jobs] have their answers here, so the
  /// session can make them without holding the screen. Any that do
  /// not are sent to [dealWorker], and when an answer comes back the
  /// steps waiting on it are looked at again: deferred ones drained,
  /// this side's own acted on. Always true without a worker.
  ///
  /// A job the worker cannot make is a worker failed for good, and a
  /// device that can no longer deal ([_cannotWork]); nothing is sent
  /// to it after that, and what waits on it waits for good. There is
  /// no timeout here. A worker that is slow — a phone, a queue of other
  /// tables' work, a device asleep in a pocket — is slow, and the
  /// table's deadlines are what judge a device too slow to play; one
  /// that has stopped is the worker's to notice ([ResilientDealWorker]).
  bool _workedOut(List<DealJob> jobs) {
    final p = _prepared;
    final w = dealWorker;
    if (p == null || w == null) return true;
    if (_cannotDeal != null) return jobs.every(p.has);
    for (final job in jobs) {
      if (p.has(job) || !_working.add(job.key)) continue;
      w.run(job, done: (answer) {
        _working.remove(job.key);
        p.put(job, answer);
        _lookAgainAfterWork();
      }, failed: (why) => _cannotWork(job, why));
    }
    return jobs.every(p.has);
  }

  /// Jobs sent to the worker and not answered, by key. A job that
  /// failed stays here: never sent again, never made here.
  final Set<String> _working = {};

  /// The worker has failed for good ([ResilientDealWorker]), and this
  /// device with it ([cannotDeal]).
  ///
  /// Said once, at the first job to fail — every job after would fail
  /// the same way, and none is sent — and acted on a moment later,
  /// from outside whatever this side was in the middle of: a worker
  /// that has failed for good fails a job inside [DealWorker.run],
  /// which can be anywhere.
  void _cannotWork(DealJob job, Object why) {
    if (_cannotDeal != null || table.closed) return;
    Zone.current.handleUncaughtError(DealWorkFailed(job, why), StackTrace.current);
    _cannotDeal = '$why';
    table.trace('cannot deal: $why');
    clock.schedule(0, () {
      if (table.closed) return;
      if (table.amSeated) {
        table.leave();
        table.notify();
      } else {
        table.notify();
        table.close();
      }
    });
  }

  bool _lookAgainDue = false;

  /// Work back from the worker: the deals go on from where they
  /// stopped for it ([DealSession.resume]) — a first deck, a departed
  /// seat's cards opened — and the table moves with them as it does
  /// when a step settles or a secret is rebuilt; the steps waiting on
  /// it are looked at again. Once however many answers came together,
  /// and never from inside the look that sent the work, which has yet
  /// to put its own step aside to wait.
  void _lookAgainAfterWork() {
    if (_lookAgainDue || table.closed) return;
    _lookAgainDue = true;
    clock.schedule(0, () {
      _lookAgainDue = false;
      if (table.closed) return;
      for (final d in List.of(_dealsByHand.values)) {
        d.resume();
      }
      advance();
      table.resumeStalled();
      table.drainFuture();
      act();
      table.notify();
    });
  }
}
