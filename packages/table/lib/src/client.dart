/// One seat's view of a table, and the protocol that keeps four seats
/// agreeing without a server.
///
/// The engine is the referee: every client runs the same rules over the
/// same deal, so a play is accepted because everyone's copy of the rules
/// accepts it, not because anyone says so. What the protocol adds is
/// **when** a turn is settled. Every turn is a race between two pools of
/// signatures: the seat's own action (a pass or a play, signed by the
/// seat and witnessed by others), and the seat's removal (a boot pressed
/// once the seat's clock has run out, or an absence claimed after a
/// silence, both by the table's timing, pressed or countersigned by
/// others). Each participant signs one side or the other, never both,
/// and a side wins with a strict majority of the participants. Then,
/// and only then, the next turn opens, so there is never anything to
/// roll back. A seat's own signed leave is carried by a majority in the
/// same way. When everyone has signed and neither side has a
/// majority — an even table split down the middle — the turn is stuck,
/// and the table pauses for the jury (docs/04-live-play.md), which is
/// the one party that can break it without any two peers ever deciding
/// it differently.
///
/// Nobody claims a departure from inside a hole in the network. A peer
/// presses or countersigns a boot, or claims or backs an absence, only
/// while it has heard from a majority of the participants recently; a
/// peer that has not is the one that is cut off, and says so instead.
///
/// **Who the majority is of** has to be the same at every peer, however
/// late each one hears the news, so it is a function of the record and
/// not of the clock: the participants at turn T are the humans who sat
/// down, less anyone whose removal was made at T or earlier. Every
/// removal — boot, absence, leave — names the turn it is made at, and is
/// only backed by peers standing at that same turn; in the record it
/// sits ahead of the action at that turn. A peer that has yet to hear
/// of a removal measures against a larger set, which can only make it
/// wait, never settle something the others would not; the two sides of
/// one race are disjoint within any one set, so the sides cannot both
/// win.
///
/// Bot seats need no events at all. A bot's move is a function of the
/// deal and the record, so every peer computes it the moment the bot's
/// turn opens and moves on (docs/04-live-play.md).
///
/// At a **sealed** table (docs/03-fair-deal.md) the cards come from the
/// verifiable deal rather than the seed, and the deal is turns like any
/// other: four rounds of one per seat — keys, a shuffle in seat order,
/// reveal tokens, the lead card declared — each a race the seat wins by
/// acting or loses by removal, and four audit turns at the end of the
/// hand. A bot's step is public work everyone computes; a person who
/// leaves becomes a bot whose secret the others rebuild from the pieces
/// it escrowed with its keys, released by the seats and the jurors that
/// hold them. A pass carries the tokens that open the cards sealed to
/// the receiver; a play carries the token that opens its card for all.
/// The section "the deal" below drives it; deal.dart's DealSession does
/// the cryptography.
///
/// Not in this version: any defence against a participant signing both
/// sides of a race, which honest clients never do and the record's
/// verification exposes after the fact.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import 'clock.dart';
import 'events.dart';
import 'journal.dart';
import 'model.dart';
import 'sealed_pass.dart';
import 'signing.dart';
import 'spec.dart';
import 'time_bank.dart';
import 'timing.dart';
import 'jury.dart';
import 'transport.dart';

/// How a modified client lies (docs/03-fair-deal.md), for the
/// simulator. A seat saying it holds the two of clubs nowhere has
/// nothing to prove, and nothing can be made to prove it; a token
/// sealed to one pair of eyes is checked by an argument beside it.
/// What the table does about each is worth a test, and there is no
/// testing it without committing it.
enum Lie {
  /// Says it holds the two of clubs nowhere and deals itself the hand
  /// all the same: it alone knows who leads, and it plays on while the
  /// rest of the table waits for a lead that is never coming. The loud
  /// version, and the table's clock has it at the audit it will not
  /// answer.
  declare,

  /// The same word, and then it waits with everybody else and answers
  /// the early audit like an honest seat. The patient version: nothing
  /// it does is out of step, and only the opened deal says which seat
  /// was dealt the card it disclaimed.
  hide,

  /// Seals its pass to nothing: three cards of the right shape that the
  /// seat it passed to could never open. It gets no further than its own
  /// turn — every seat checks the argument beside a seal, and a pass
  /// that fails it is not taken — and the clock has its seat there.
  seal,
}

/// Why a table is not moving.
enum Pause {
  /// A removal is proposed that the players at the table cannot decide
  /// among themselves — two humans, one silent.
  waitingForJury,

  /// A removal is proposed and there are not enough peers reachable to
  /// carry it: the table is partitioned or most of it has gone quiet.
  waitingForPeers,

  /// A departed seat's hand is being opened from the pieces of its
  /// secret the others escrowed; its bot cannot move until it is.
  openingHand,

  /// The deal is done and nobody declared the lead card: its holder
  /// lied, which only a modified client does, and the hand cannot
  /// start. The audit would expose who; the table says so and waits.
  waitingForLead,
}

/// Why a game ended without finishing: a connection failure, and which.
enum Failure {
  /// A turn the table is stopped at that nobody left could move, and
  /// has been, for [TableTiming.quorumLostMs]: a seat nobody left
  /// could open — a held bot seat with its own juror gone and fewer
  /// than [escrowThreshold] of the jurors holding a piece of it still
  /// heard, or a departed person's with none — or a turn put to a jury
  /// none of whose jurors is left to rule on it.
  jurorQuorumLost('juror quorum lost');

  const Failure(this.label);

  /// As the player is told it.
  final String label;
}

/// A settled turn or a departure, as it goes in the record.
class Decision {
  const Decision({
    required this.turn,
    required this.event,
    required this.witnesses,
    this.removal = false,
    this.among = const {},
    this.jury = false,
    this.verdict,
  });

  /// True for a jury proposal that carried: the hand's jurors, agreed
  /// by the table. Kept beside the record ([TableClient.juries]), not
  /// in it — it is authority for verdicts, not a move.
  final bool jury;

  /// The juror's verdict that settled this turn, when the players could
  /// not: it names the winning event, and the verifier checks the juror
  /// against the hand's jury.
  final TableEvent? verdict;

  /// The turn settled, or the turn at which a departure was made.
  final TurnId turn;

  /// The action (pass or play), or one of the claims that carried the
  /// removal (a boot, an absence, or the leave itself).
  final TableEvent event;

  /// Who backed it, the author included.
  final Set<PublicKey> witnesses;

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
  /// every peer; ordering by position (TurnId.position), with
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
    final endA = removal && event.kind == EventKind.ended;
    final endB = other.removal && other.event.kind == EventKind.ended;
    if (endA != endB) return endA ? 1 : -1;
    if (removal != other.removal) return removal ? -1 : 1;
    return event.seat.compareTo(other.event.seat);
  }

  @override
  String toString() =>
      '$turn ${jury ? 'JURY' : removal ? 'OUT' : 'ok'} $event by ${witnesses.length}${verdict != null ? ' by verdict' : ''}';
}

/// The order a hand's juries come in: where each was proposed, then by
/// whose seat, then by id. Read from the proposal alone, so that every
/// side, whatever order it heard them in, and the verifier, which is
/// handed them loose, put them the same way round — the first is the
/// draw a bot seat's holder is read from. Id alone would not do: a
/// hand drawn again at one trick could then put a redraw ahead of the
/// draw the table played by.
int compareJuries(Decision a, Decision b) {
  final x = a.event.turn;
  final y = b.event.turn;
  if (x.hand != y.hand) return x.hand.compareTo(y.hand);
  if (x.position != y.position) return x.position.compareTo(y.position);
  final by = a.event.seat.compareTo(b.event.seat);
  return by != 0 ? by : a.event.id.compareTo(b.event.id);
}

class TableClient {
  TableClient({
    required this.spec,
    required this.signer,
    required this.transport,
    required this.clock,
    int? silenceAfterMs,
    this.heartbeatMs = 5000,
    this.presence,
    this.crypto,
    this.dealWorker,
    this.journal,
    Random? random,
  })  : _random = random,
        _silenceAfterMs = silenceAfterMs,
        game = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target),
        holders = List.of(spec.seats),
        _humans = {for (final h in spec.seats) if (h is HumanSeat) h.key} {
    if (spec.sealed && crypto == null) throw ArgumentError('a sealed table needs the deal\'s cryptography');
  }

  final TableSpec spec;
  final Signer signer;
  final Transport transport;
  final Clock clock;

  /// The table's clocks, as whoever started it chose them and the
  /// start event said (timing.dart): the same at every seat and juror.
  TableTiming get timing => spec.timing;

  /// The clock every seat plays against: a grace per decision, a bank
  /// per hand, Boot once both are spent (time_bank.dart).
  TimeBank get timeBank => timing.bank;

  /// How long a person may be silent before the table removes them:
  /// the table's, unless a test asked for a shorter one.
  int get silenceAfterMs => _silenceAfterMs ?? timing.silenceMs;
  final int? _silenceAfterMs;
  final int heartbeatMs;

  /// Who is online, and how a juror is summoned; null at a table that
  /// draws no jury.
  final Presence? presence;

  /// The deal's primitives, at a sealed table.
  final DealCrypto? crypto;

  /// What this device has said here and the secrets its deal keys were
  /// made from, written as it goes; and, for a client built again after
  /// a reload, read back before it says anything new (journal.dart).
  final TableJournal? journal;

  /// Where the deal's slow calls are made, when not on the thread this
  /// runs on: a Web Worker in the browser, an isolate on the VM
  /// (packages/deal, work.dart). Null makes them here, as the
  /// simulator does unless it is asked not to.
  ///
  /// With one, a deal step is taken up once its checking has been
  /// worked out there, and this side's own step is said once it has
  /// been made there ([_workedOut]); until then the step waits where
  /// a step waits for anything else it is checked against. The table
  /// sees nothing different but the time the work took, which it
  /// spent before anyway — only now with the screen still drawing.
  ///
  /// Nothing slow is made here instead, ever. A worker that fails is
  /// replaced once ([ResilientDealWorker]); one that fails again is a
  /// bug, raised as one ([DealWorkFailed]), and this device can no
  /// longer deal ([cannotDeal]). A slow call nobody described is
  /// refused and raised the same way ([PreparedDeal]).
  final DealWorker? dealWorker;

  /// Why this device cannot deal, once its worker has failed for good;
  /// null while it can.
  ///
  /// A seat at the table leaves it at once. A device that cannot check
  /// the others' deal steps can never witness them, and at a table of
  /// two people a step needs both: waiting to be booted at its own turn
  /// would be waiting for a turn that never comes, with the other
  /// player's shuffle stopped in front of it. Leaving, the seat goes
  /// to a bot and the table plays on. A juror stops following the
  /// table; the seat it holds goes to the escrow at its deadline, as a
  /// quiet juror's does. Either way the device stops saying it is
  /// online, and no table draws it after (presence_relay.dart,
  /// [RelayPresence.canServe]).
  String? get cannotDeal => _cannotDeal;
  String? _cannotDeal;

  /// The session's primitives, answering the slow calls from what
  /// [dealWorker] made.
  late final PreparedDeal? _prepared = dealWorker == null || crypto == null ? null : PreparedDeal(crypto!);

  /// The slow calls refused for want of an answer from the worker:
  /// steps whose cost was not described. Every one is a bug.
  int get dealCallsRefused => _prepared?.refused ?? 0;

  /// Where the deal's secrets and seeds come from: secure by default;
  /// the simulator seeds it, so a table replays.
  final Random? _random;

  final HeartsGame game;

  /// Who holds each seat now; humans become bots as they go.
  final List<SeatHolder> holders;

  /// Every human who sat down.
  final Set<PublicKey> _humans;

  /// The accounts that sat down here (spec.dart), whichever of their
  /// devices sat: a jury is drawn from nobody of theirs, since another
  /// device of a player's account is the player (docs/04-live-play.md).
  late final Set<String> _seatedAccounts = spec.accounts;

  /// Whether [key] is a device of an account seated here, as presence
  /// says whose each key is.
  bool _ofThisTable(PublicKey key) => _humans.contains(key) || _seatedAccounts.contains(presence?.accountOf(key) ?? key);

  /// The humans still at the table.
  Set<PublicKey> get participants => _humans.difference(_removedAt.keys.toSet());

  /// Every settled turn and departure, in canonical order.
  final List<Decision> record = [];

  /// Every jury proposal that carried, in the order they carried: the
  /// authority behind any verdict in the record. Two peers may hold
  /// different ones for the same hand — a replacement drawn when a
  /// jury went quiet, a proposal that carried late — which is why they
  /// travel with the record rather than in it.
  final List<Decision> juries = [];

  /// Turns settled in the current hand.
  int step = 0;

  /// The last hand's score sheet, kept because the game moves straight
  /// on to the next deal.
  ({int hand, List<int> scores, List<int> totals, int? moonShooter})? lastHand;

  /// Cards played this hand, what a seated player has seen.
  final Set<Card> played = {};

  Pause? get pause => _pause;
  Pause? _pause;

  /// Receives a line for every transition, for traces. Off by default.
  void Function(String line)? log;

  void _trace(String what) {
    final l = log;
    if (l != null) l('${clock.nowMs.toString().padLeft(7)} ${signer.publicKey.substring(0, 4)}/$mySeat $what');
  }

  /// The game is over — and at a sealed table its last hand audited,
  /// so the record can be checked to the end.
  bool get done => game.phase == Phase.gameOver && (!spec.sealed || _auditDone);

  /// Fires after any change of state a view might show. Synchronous, so
  /// a listener sees the change in the same tick it happens — which is
  /// what lets the simulator run a whole game without yielding.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast(sync: true);

  int? get mySeat => spec.seatOf(signer.publicKey);
  bool get amSeated => mySeat != null && !_removedAt.containsKey(signer.publicKey);

  /// The player owes a pass, and has not yet made one that is waiting
  /// on the table.
  bool get awaitingMyPass =>
      amSeated && game.phase == Phase.passing && !game.hasPassed(mySeat!) && !_left && !_acted(TurnId.pass(game.handNumber, mySeat!));

  /// It is the player's turn and they have not yet played into it.
  bool get awaitingMyPlay =>
      amSeated && game.phase == Phase.playing && game.currentSeat == mySeat && !_left && !_acted(TurnId.play(game.handNumber, _playIndex));

  bool _acted(TurnId turn) => _races[turn]?.action != null;

  /// Whether this device knows its own events are not getting out —
  /// every relay refusing them (relays.dart). A peer in that state is
  /// the least qualified to say anyone else is absent: what looks like
  /// their silence may be this device's own deafness, and the claim
  /// would not reach the table anyway. So while it holds, this peer
  /// neither claims absence, nor countersigns a boot, nor offers one.
  bool writesRefused = false;

  /// Whether the Boot button shows for [seat]: a human's turn, open
  /// past its grace with the seat's bank spent, by this peer's clock.
  bool canBoot(int seat) {
    if (!amSeated || seat == mySeat || holders[seat] is! HumanSeat) return false;
    if (!connectedToMajority || writesRefused) return false;
    // Backing their leave, this side has given its voice on the seat.
    if (!_mayBackBoot((holders[seat] as HumanSeat).key)) return false;
    if (_catchingUp((holders[seat] as HumanSeat).key)) return false;
    // A seat waiting on an answer it is owed is not idle: three of its
    // cards will not open and it cannot play what it cannot see
    // (docs/03-fair-deal.md). It waits the clock a device answers by,
    // and no longer — a table that waited for ever on a passer that
    // will not answer would be the worse hole of the two.
    final t = _openTurnOf(seat);
    if (t == null) return false;
    // A hand being opened to be given up has one thing left to settle,
    // and it is not the turn it stopped at ([_openTheHand]).
    if (_openingAudit && !t.isAudit) return false;
    return _overdue(t, seat) || _silent((holders[seat] as HumanSeat).key);
  }

  // ---- the time bank -----------------------------------------------------

  /// What each seat has spent of its bank this hand, as this peer saw
  /// it: the part of every settled decision past its grace, measured
  /// from the turn opening here to its action carrying here. Keyed by
  /// hand and seat; a new hand starts from nothing.
  final Map<(int, int), int> _spentMs = {};

  /// What [seat] has left of its bank this hand, by this peer's clock.
  int bankLeftMs(int seat) {
    final left = timeBank.bankMs - (_spentMs[(game.handNumber, seat)] ?? 0);
    return left < 0 ? 0 : left;
  }

  /// How long [turn] may stay open before Boot, for [seat].
  int _allowanceMs(TurnId turn, int seat) => timeBank.allowanceMs(turn, bankLeftMs(seat));

  bool _overdue(TurnId turn, int seat) => clock.nowMs - _openedAt[turn]! >= _allowanceMs(turn, seat);

  /// The bank's accounting for [turn], once [seat]'s action has carried:
  /// what it took past the grace comes off the seat's bank for the
  /// hand. A turn this peer never saw open — one caught up on from the
  /// record — costs nothing here, since there is nothing to measure.
  void _spend(TurnId turn, int seat) {
    if (!timeBank.banks(turn) || holders[seat] is! HumanSeat) return;
    final opened = _openedAt[turn];
    if (opened == null) return;
    final took = clock.nowMs - opened;
    // What this device took over its own card, whole: its own account
    // of itself, which is the only pace anybody can measure without
    // dispute (pace.dart). The pass is one decision over thirteen
    // cards and is not one of them.
    if (seat == mySeat && turn.isPlay) myCardMs.add(took);
    final over = took - timeBank.graceOf(turn);
    if (over > 0) _spentMs[(turn.hand, seat)] = (_spentMs[(turn.hand, seat)] ?? 0) + over;
  }

  /// How long this device took over each of its own cards, in order:
  /// the clock started when the turn opened here and stopped when the
  /// play carried here. Nobody else's business and in no signed
  /// record — see pace.dart for why it cannot be.
  final List<int> myCardMs = [];

  /// Milliseconds [seat] has left before it can be booted, once the
  /// grace on its open turn is spent — the clock the badge shows — or
  /// null: no open turn, a turn still within its grace, or a bot's.
  int? clockMs(int seat) {
    if (holders[seat] is! HumanSeat) return null;
    final t = _openTurnOf(seat);
    if (t == null || !timeBank.banks(t)) return null;
    final elapsed = clock.nowMs - _openedAt[t]!;
    if (elapsed < timeBank.graceOf(t)) return null;
    final left = _allowanceMs(t, seat) - elapsed;
    return left < 0 ? 0 : left;
  }

  /// A peer whose recent heartbeats put it behind this one is not idle,
  /// it is still receiving the game; nobody boots a player for that.
  ///
  /// Unless it has been saying the same thing for longer than any one
  /// decision may take. A peer that is really catching up moves — every
  /// event it applies is another step — so one that has not moved is
  /// not behind, it has stopped: cut off past what it can recover from,
  /// or a modified client that took a path of its own through the hand
  /// and will never reach this one. The seat that says it holds the
  /// lead card nowhere and then deals itself the hand
  /// (docs/03-fair-deal.md) is exactly that, and without this it would
  /// be behind for ever and never bootable.
  bool _catchingUp(PublicKey key) {
    final pos = _lastPosition[key];
    if (pos == null || !_recent(key)) return false;
    final (hand, step) = pos;
    if (hand > game.handNumber || (hand == game.handNumber && step >= this.step)) return false;
    return clock.nowMs - (_positionMovedAt[key] ?? clock.nowMs) < timeBank.graceMs + timeBank.bankMs;
  }

  /// Milliseconds until [canBoot] for [seat], or null when there is no
  /// open turn for it.
  int? bootCountdownMs(int seat) {
    final t = _openTurnOf(seat);
    if (t == null) return null;
    final holder = holders[seat];
    if (holder is HumanSeat && _silent(holder.key)) return 0;
    final left = _allowanceMs(t, seat) - (clock.nowMs - _openedAt[t]!);
    return left < 0 ? 0 : left;
  }

  // ---- the model's view ------------------------------------------------

  /// Where [turn]'s race stands, in the model's terms; null for a turn
  /// this peer has not opened.
  TurnState? turnStateOf(TurnId turn) {
    final race = _races[turn];
    if (race == null) return null;
    if (race.settled) {
      if (_endedAt == turn) return TurnState.ended;
      if (_removedAtTurn.contains(turn)) return TurnState.settledByRemoval;
      return _onRecord.contains(turn) ? TurnState.settledByAction : TurnState.settledSilently;
    }
    if (race.split) return TurnState.split;
    if (race.boots.isNotEmpty) return TurnState.contested;
    if (race.action != null) return TurnState.acting;
    return TurnState.open;
  }

  /// Every turn this peer has opened, with its state.
  Map<TurnId, TurnState> get turnStates => {for (final t in _races.keys) t: turnStateOf(t)!};

  /// The turns settled by an action on the record — not by a removal,
  /// not a jury's — whatever the hand.
  final Set<TurnId> _onRecord = {};

  /// Whether [turn] was settled here by an action the record holds:
  /// something a side that is behind can be carried to.
  bool onRecord(TurnId turn) => _onRecord.contains(turn);

  /// Where the current hand stands ([HandState]).
  HandState get handState {
    if (_openingAudit) return HandState.opening;
    switch (game.phase) {
      case Phase.dealing:
        return spec.sealed && _deal?.hand != game.handNumber ? HandState.awaitingJury : HandState.dealing;
      case Phase.passing:
        return HandState.passing;
      case Phase.playing:
        return HandState.playing;
      case Phase.handOver:
      case Phase.gameOver:
        return spec.sealed && !_auditDone ? HandState.auditing : HandState.over;
    }
  }

  /// How each hand this side has left behind ended: over, given up
  /// opened, or abandoned in its deal.
  final Map<int, HandState> _handEnds = {};

  /// How [hand] ended here, or null while it has not. The last hand
  /// of a finished game ends with the game, not by moving on.
  HandState? handOutcome(int hand) => _handEnds[hand] ?? (done && hand == game.handNumber ? HandState.over : null);

  /// Where a bot seat the current hand's jury holds stands; null for a
  /// seat that is a person's or a bot nobody holds.
  HeldSeatState? heldSeatState(int seat) {
    if (botHolders(game.handNumber)[seat] == null) return null;
    return (_deal?.gone.contains(seat) ?? false) ? HeldSeatState.escrowed : HeldSeatState.held;
  }

  /// The jury draw each hand's deal was sealed to: the record's, once
  /// the keys that say it have settled here ([_checkSealed]), and until
  /// then the one this side read.
  String? sealedTo(int hand) => _sealedTo.containsKey(hand) ? _sealedTo[hand] : _heldFrom[hand];

  /// The action this side holds for [turn], if any.
  TableEvent? actionAt(TurnId turn) => _races[turn]?.action;

  /// Whether this side has backed the action it holds for [turn].
  bool backs(TurnId turn) => _races[turn]?.forAction.contains(signer.publicKey) ?? false;

  /// The seats of the current hand this side has given to the escrow
  /// or seen depart: the ones it releases its pieces of.
  Set<int> get goneSeats => {...?_deal?.gone};

  /// What this side is waiting for, each with who can end the wait
  /// ([Wait]). Read from the same state the client acts on; it decides
  /// nothing.
  List<Wait> get waits {
    final out = <Wait>[];
    if (done || _failure != null) return out;
    if (handState == HandState.awaitingJury) out.add(const Wait(WaitKind.jury, outside: true));
    for (final e in _races.entries) {
      final t = e.key;
      final race = e.value;
      if (race.settled) continue;
      final seat = _turnSeat[t];
      if (seat == null) continue;
      if (race.split) {
        out.add(Wait(WaitKind.verdict, turn: t, seat: seat, movers: _jurorsOf(t.hand)));
        continue;
      }
      if (race.action != null || race.boots.isNotEmpty || race.ends.isNotEmpty) {
        // Backing from those who have not given it — for the move, a
        // removal, or the game's end — or, once a voter's silence has
        // split the turn, the hand's jurors' ruling.
        final of = _participantsAt(t);
        out.add(Wait(WaitKind.witnesses, turn: t, seat: seat, movers: {
          ...of.difference(race.forAction).difference(race.forRemoval).difference(race.forEnd),
          ..._jurorsOf(t.hand),
        }));
        continue;
      }
      final holder = holders[seat];
      if (_stalled.containsKey(t)) {
        // A seat's secret, from those holding its pieces: the jury the
        // deal was sealed to and whoever was given one since, and for
        // a person's seat the people still at the table beside them.
        out.add(Wait(WaitKind.secret, turn: t, seat: seat, movers: {
          ..._pieceHolders(t.hand, seat),
          if (botHolders(t.hand)[seat] == null) ...participants,
        }));
        continue;
      }
      // A seat's move, or the seat's removal: a person's by the people
      // at the table, whose clock and whose claim of silence can each
      // end the wait; a held seat's by this side, which gives it to the
      // escrow when its juror is silent or out of time, and then by
      // those holding its pieces.
      if (holder is HumanSeat) {
        out.add(Wait(WaitKind.action, turn: t, seat: seat, movers: {holder.key, ...participants}));
        continue;
      }
      final held = botHolders(t.hand)[seat];
      if (held == null) continue; // everyone's to work out, and being worked out
      // Its juror, or the people's claim that gives it to the escrow;
      // once given, the jurors holding a piece of it.
      out.add(Wait(WaitKind.action,
          turn: t,
          seat: seat,
          movers: {held, if (_isEscrowed(t.hand, seat)) ..._pieceHolders(t.hand, seat) else ...participants}));
    }
    return out;
  }

  /// The turn [seat]'s person was removed at here, or null.
  TurnId? removedAt(int seat) => switch (spec.seats[seat]) {
        HumanSeat(:final key) => _removedAt[key],
        _ => null,
      };

  SeatState seatStateOf(int seat) {
    final original = spec.seats[seat];
    if (original is BotSeat) return SeatState.bot;
    final key = (original as HumanSeat).key;
    final how = _removedHow[key];
    return switch (how) {
      null => SeatState.human,
      EventKind.leave => SeatState.left,
      EventKind.boot => SeatState.booted,
      _ => SeatState.absent,
    };
  }

  TableState get tableState {
    if (done) return TableState.finished;
    if (_failure != null) return TableState.failed;
    return switch (_pause) {
      null => TableState.playing,
      Pause.waitingForJury => TableState.pausedForJury,
      Pause.waitingForPeers => TableState.pausedForPeers,
      Pause.openingHand || Pause.waitingForLead => TableState.pausedForDeal,
    };
  }

  final Set<TurnId> _removedAtTurn = {};
  final Map<PublicKey, EventKind> _removedHow = {};

  /// The open races and pending claims, for traces and tests.
  String describe() {
    final b = StringBuffer();
    b.writeln('${signer.publicKey.substring(0, 6)} seat $mySeat: hand ${game.handNumber} ${game.phase.name} '
        'step $step current ${game.currentSeat} pause $_pause participants ${participants.length} '
        'holders $holders');
    if (_failure != null) b.writeln('  ended: ${_failure!.label}, at ${_failedAt?.turn} for seat ${_failedAt?.seat}');
    final held = botHolders(game.handNumber);
    if (held.isNotEmpty) {
      b.writeln('  bot seats held: ${held.entries.map((e) => '${e.key} by ${e.value.substring(0, 4)}${e.value == signer.publicKey ? ' (here)' : ''}').join(', ')}');
    }
    for (final e in _races.entries) {
      if (e.value.settled) continue;
      final r = e.value;
      b.writeln('  open ${e.key} seat ${_turnSeat[e.key]}: action ${r.action?.kind.name} by '
          '${r.forAction.map((k) => k.substring(0, 4))} boots ${r.boots.length} by ${r.forRemoval.map((k) => k.substring(0, 4))} '
          'needed ${_majority(_participantsAt(e.key))} of ${_participantsAt(e.key).length}');
    }
    if (_future.isNotEmpty) {
      b.writeln('  deferred ${_future.length}: '
          '${_future.take(4).map((e) => '${e.kind.name}@${_atOf(e)}')}');
    }
    final jurors = _jurorsOf(game.handNumber);
    if (jurors.isNotEmpty || needsJuror) {
      b.writeln('  jury: ${jurors.map((k) => k.substring(0, 4))} live ${_liveJurors(game.handNumber).map((k) => k.substring(0, 4))}'
          '${needsJuror ? ' — nobody to draw from' : ''}');
    }
    for (final e in _proposals.entries) {
      if (e.value.settled) continue;
      b.writeln('  proposed jury ${e.key.substring(0, 6)} by ${e.value.forAction.map((k) => k.substring(0, 4))}');
    }
    if (_serving.isNotEmpty) b.writeln('  serving as juror for hands ${_serving.keys.toList()}; appeals ${_appealSeenAt.keys}');
    b.writeln('  connected ${connectedToMajority ? 'yes' : 'no'}; heard '
        '${_humans.where((k) => k != signer.publicKey).map((k) => '${k.substring(0, 4)} '
            '${_lastHeard[k] == null ? 'never' : '${clock.nowMs - _lastHeard[k]!} ms ago'}').join(', ')}');
    return b.toString();
  }

  /// Where a deferred event sits, for [describe]. A release or a
  /// top-up part is about a hand rather than a turn, and asking one
  /// for its turn throws.
  String _atOf(TableEvent e) =>
      e.kind == EventKind.release || e.kind == EventKind.topup ? 'h${e.hand}' : '${e.turn}';

  // ---- internals ------------------------------------------------------

  final Map<TurnId, _Race> _races = {};
  final Map<TurnId, int> _openedAt = {};
  final Map<TurnId, int> _turnSeat = {};
  final Map<String, Set<PublicKey>> _earlyWitnesses = {};
  final Map<String, List<TableEvent>> _earlyWitnessEvents = {};
  final Map<TurnId, String> _myWitness = {};
  final Map<PublicKey, TurnId> _removedAt = {};
  final Map<PublicKey, int> _lastHeard = {};

  // The jury (jury.dart, and the section below).
  //
  // A time before any clock. Not `-1 << 30`: on the web a shift of a
  // negative number comes out unsigned, and a sentinel that is meant
  // to be far in the past lands far in the future.
  static const _never = -1000000000;
  final Map<String, _Race> _proposals = {};
  final Map<int, String> _myJuryWitness = {};
  final Map<String, TableEvent> _myJuryWitnessEvents = {};
  final Map<String, int> _juryAt = {};
  final Map<PublicKey, int> _jurorHeard = {};
  final Map<TurnId, int> _lastAppealAt = {};
  int _lastProposedAt = _never;
  int _lastCalledAt = _never;
  int _proposedForHand = -1;
  int _proposalsThisHand = 0;

  /// True when this table found nobody online to draw a jury from, and
  /// has said so.
  bool needsJuror = false;

  /// True while a hand is held back for want of a jury big enough to
  /// hold its bot seats: there are jurors, but not enough of them for
  /// a seat to survive its holder going (jury.dart, [juryToHoldBots]).
  /// The table says so rather than dealing a hand whose bots everyone
  /// can see.
  bool _shortOfJurors = false;

  bool get shortOfJurors => _shortOfJurors;

  // As a juror: the hands this client serves, each with the jury it was
  // summoned into, foreman first; the appeals heard; the verdicts given.
  final Map<int, List<PublicKey>> _serving = {};

  /// The first hand this client was summoned to. Everything before it
  /// is history the client reads and has no part in: any seat this key
  /// held earlier was held by a client that has since been let go of,
  /// with secrets this one never had ([_beforeSummons]); and the duty
  /// starts no client on a summons to a hand that one had reached
  /// (juror_duty.dart).
  int? _summonedFrom;

  /// What this side would have said about a hand before its summons,
  /// and did not ([_emit]): nothing, when every way of acting in one is
  /// closed where it starts, which the chaos walk holds it to.
  int saidBeforeSummons = 0;
  final Map<TurnId, int> _appealSeenAt = {};

  /// When each appeal was last heard here. An appeal stands while the
  /// people say it ([appealStandsMs]); one gone unheard that long is a
  /// table this juror has lost, or one that no longer asks.
  final Map<TurnId, int> _appealHeardAt = {};
  final Map<TurnId, int> _verdictAt = {};
  final Map<TurnId, int> _waitSaidAt = {};

  /// Where each peer last said it stood, from its heartbeats.
  final Map<PublicKey, (int, int)> _lastPosition = {};

  /// When each peer last said something different: a peer receiving the
  /// game moves, and one that is not, does not.
  final Map<PublicKey, int> _positionMovedAt = {};

  void _notePosition(PublicKey key, int hand, int step) {
    final was = _lastPosition[key];
    if (was == null || was.$1 != hand || was.$2 != step) _positionMovedAt[key] = clock.nowMs;
    _lastPosition[key] = (hand, step);
  }
  final List<TableEvent> _future = [];
  final Set<String> _seen = {};
  final List<Cancel> _timers = [];
  StreamSubscription<void>? _incoming;
  StreamSubscription<void>? _drops;
  bool _left = false;
  bool _closed = false;
  bool _notifying = false;
  bool _notifyAgain = false;

  void start() {
    for (final k in _humans) {
      _lastHeard[k] = clock.nowMs;
    }
    _incoming = transport.incoming.listen((m) => _onMessage(m.from, m.message));
    _drops = transport.disconnected.listen(_onDisconnected);
    // Built again after a reload: this device's own word first, as if
    // it had just heard itself, so that every turn it already spoke at
    // has its move or its vote in place before anything opens there,
    // and nothing is signed afresh against it.
    final restored = journal?.saidSoFar ?? const <Map<String, Object?>>[];
    for (final e in restored) {
      _onMessage(signer.publicKey, e);
    }
    // Back from a reload, heard at once: the table has been counting
    // this seat's silence since its connection closed, and a heartbeat
    // is also what asks for the turns missed.
    _timers.add(clock.schedule(restored.isEmpty ? heartbeatMs : 0, _heartbeat));
    _timers.add(clock.schedule(1000, _tick));
    _openHand();
    _notify();
  }

  void close() {
    _closed = true;
    _incoming?.cancel();
    _drops?.cancel();
    for (final cancel in _timers) {
      cancel();
    }
    _timers.clear();
    _changes.close();
  }

  // ---- what the player does -------------------------------------------

  void pass(List<Card> cards) {
    if (!awaitingMyPass) return;
    sayPass(mySeat!, cards);
  }

  /// A pass for [seat], said rather than worked out by everyone: a
  /// player's own, or a bot seat's by the juror that holds it
  /// (docs/04-live-play.md). A bot seat nobody holds needs no event —
  /// every peer computes the same pass from a hand it can all see.
  void sayPass(int seat, List<Card> cards) {
    final turn = TurnId.pass(game.handNumber, seat);
    if (!_races.containsKey(turn) || _races[turn]!.settled) return;
    final body = <String, Object?>{'hand': game.handNumber, 'turn': turn.index, 'seat': seat};
    if (spec.sealed) {
      // The cards stay hidden: the positions move, and the tokens that
      // open them go to the receiver alone.
      final d = _deal!;
      final positions = [for (final c in cards) d.positionOf(seat, c.index)];
      if (positions.any((p) => p == null)) return;
      final to = (seat + game.passDirection.seatOffset) % seatCount;
      final m = d.passMessage(to, [for (final p in positions) p!], from: seat);
      if (m == null) return;
      if (seat == mySeat && lies == Lie.seal && m['sealed'] != null) {
        // Sealed to nothing anybody holds: the shape of a pass, and
        // three cards the receiver will never open (docs/03-fair-deal.md).
        final rng = _random ?? Random();
        m['sealed'] = [for (var i = 0; i < passSize; i++) base64.encode([for (var b = 0; b < sealedBytes; b++) rng.nextInt(256)])];
      }
      body.addAll(m);
    } else {
      body['cards'] = [for (final c in cards) c.code];
    }
    _emit(EventKind.pass, body);
  }

  void play(Card card) {
    if (!awaitingMyPlay) return;
    if (!game.legalPlaysFor(mySeat!).contains(card)) return;
    sayPlay(mySeat!, card);
  }

  /// A play for [seat], said rather than worked out by everyone: as
  /// [sayPass], and for the same reason.
  void sayPlay(int seat, Card card) {
    final turn = TurnId.play(game.handNumber, _playIndex);
    final body = <String, Object?>{'hand': game.handNumber, 'turn': turn.index, 'seat': seat, 'card': card.code};
    if (spec.sealed) {
      final d = _deal!;
      final p = d.positionOf(seat, card.index);
      if (p == null) return;
      final m = d.playToken(p);
      if (m == null) return;
      body.addAll(m);
      // A person's own play puts on the record the draws that have
      // brought someone into a held seat's escrow since the last one
      // that did ([_takeGrowth]).
      if (seat == mySeat && _personOf(seat) == signer.publicKey) {
        final grew = _growthToName(game.handNumber);
        if (grew.isNotEmpty) body['grew'] = grew;
      }
    }
    _emit(EventKind.play, body);
  }

  /// The polite exit: this peer's own word, carried as a boot is — the
  /// others back it as it reaches them, and a majority of the people
  /// at its turn carries it, this peer's signature its own vote
  /// ([_onLeave]). Made at this peer's current position, which is where
  /// it takes effect — unless
  /// this seat has an action or a vote in flight there, in which case
  /// it is made at the next position, so those are settled first: no
  /// peer can then hold both the action and a bot's move for the same
  /// turn, and a vote this peer cast counts the same everywhere, rather
  /// than for peers that settled the turn before the leave arrived and
  /// not for peers that did not.
  void leave() {
    if (!amSeated || _left) return;
    _left = true;
    var at = _positionOf(mySeat!);
    final votedHere = _myWitness.keys.any((t) => _atOrBefore(t, at) && _atOrBefore(at, t));
    if (_acted(at) || votedHere) at = _positionAfter(at, mySeat!);
    _emit(EventKind.leave, {'hand': at.hand, 'turn': at.index, 'seat': mySeat}, everywhere: true);
  }

  /// Presses Boot on [seat]. A no-op unless [canBoot].
  void boot(int seat) {
    if (!canBoot(seat)) return;
    final turn = _openTurnOf(seat)!;
    if (_myWitness.containsKey(turn)) return;
    if (!_mayBackBoot((holders[seat] as HumanSeat).key)) return;
    _emit(EventKind.boot, {'hand': turn.hand, 'turn': turn.index, 'seat': seat}, everywhere: true);
  }

  /// Signs, sends and accepts one event of this peer's own.
  /// [everywhere] sends it by every path the transport has: the rare
  /// events that decide something for someone else — a boot, a claim
  /// of absence, an appeal, a verdict, a leave, a complaint and its
  /// answer — must reach a peer or a juror that cannot read the relay
  /// this device writes to.
  void _emit(EventKind kind, Map<String, Object?> body, {bool everywhere = false}) {
    // A game that has ended says nothing more, to anyone.
    if (_failure != null) return;
    // Nor does a juror about a hand that was over before it was
    // summoned; that it serves at all is said in its heartbeats.
    final hand = body['hand'];
    if (kind != EventKind.heartbeat && kind != EventKind.serve && hand is int && _beforeSummons(hand)) {
      saidBeforeSummons++;
      _trace('nothing to say about hand $hand, over before this side was summoned: ${kind.name} $body');
      return;
    }
    final event = TableEvent.sign(signer, table: spec.id, kind: kind, body: body);
    journal?.said(event);
    if (kind != EventKind.heartbeat) _trace('emit ${kind.name} $body');
    transport.broadcast(event.toJson(), everywhere: everywhere);
    _accept(event);
  }

  // ---- positions ---------------------------------------------------------

  int get _playIndex => game.tricksPlayed * seatCount + game.trick.length;

  /// Where a claim about [seat] is made: the seat's own turn of the
  /// deal round or the pass or the audit while those are open — each a
  /// set of concurrent turns — otherwise the play turn that is open.
  TurnId _positionOf(int seat) => switch (game.phase) {
        _ when _openingAudit => TurnId.audit(game.handNumber, seat),
        Phase.dealing => TurnId.deal(game.handNumber, _currentDealRound, seat),
        Phase.passing => TurnId.pass(game.handNumber, seat),
        Phase.handOver || Phase.gameOver when spec.sealed => TurnId.audit(game.handNumber, seat),
        _ => TurnId.play(game.handNumber, _playIndex),
      };

  /// The position after [at] for [seat]: where a leave goes when the
  /// seat has already acted or voted at [at].
  TurnId _positionAfter(TurnId at, int seat) {
    final h = at.hand;
    final hold = PassDirection.forHand(h) == PassDirection.hold;
    if (at.isDeal) {
      if (at.dealRound < TurnId.dealRounds - 1) return TurnId.deal(h, at.dealRound + 1, seat);
      return hold ? TurnId.play(h, 0) : TurnId.pass(h, seat);
    }
    if (at.isPass) return TurnId.play(h, 0);
    if (at.isPlay) {
      if (at.playIndex + 1 < TurnId.plays) return TurnId.play(h, at.playIndex + 1);
      return spec.sealed ? TurnId.audit(h, seat) : TurnId.play(h, at.playIndex + 1);
    }
    return TurnId.deal(h + 1, 0, seat);
  }

  /// Where this peer stands in the hand, as a position (TurnId.position).
  int get _herePosition => switch (game.phase) {
        // A hand being opened rather than played ([_openTheHand]) is at
        // its audit, wherever its cards got to: there is nothing else
        // left to do with it.
        _ when _openingAudit => TurnId.passTurns + TurnId.plays,
        Phase.dealing => TurnId.dealBase + _currentDealRound * 4,
        Phase.passing => -1,
        Phase.playing => TurnId.passTurns + _playIndex,
        Phase.handOver => TurnId.passTurns + TurnId.plays,
        Phase.gameOver => done ? 1 << 20 : TurnId.passTurns + TurnId.plays,
      };

  /// Negative when [t] is behind this peer, zero when it is current
  /// here, positive when it is still to come. The turns of a deal
  /// round, the pass turns and the audit turns are each one position,
  /// current together, settled or not: a removal made at a seat's turn
  /// there has to be placeable by peers whose other turns of the set
  /// have already settled.
  int _compare(TurnId t) {
    if (t.hand != game.handNumber) return t.hand.compareTo(game.handNumber);
    return t.position.compareTo(_herePosition);
  }

  /// Whether a removal at [a] counts for a race at [b]: at or before it
  /// by position, so a removal made anywhere in a set of concurrent
  /// turns counts for every turn of the set.
  static bool _atOrBefore(TurnId a, TurnId b) {
    if (a.hand != b.hand) return a.hand < b.hand;
    return a.position <= b.position;
  }

  /// The set a majority at [turn] is of: everyone not removed by then.
  Set<PublicKey> _participantsAt(TurnId turn) =>
      {for (final k in _humans) if (!_removedAt.containsKey(k) || !_atOrBefore(_removedAt[k]!, turn)) k};

  static int _majority(Set<PublicKey> of) => of.length ~/ 2 + 1;

  // ---- the hand ---------------------------------------------------------

  /// A line a hand, for whatever this side is declining to do. What
  /// the table sees when a juror will not act is nothing at all, and
  /// nothing at all is also what a starved device looks like.
  void _sayOnce(int hand, String what) {
    if (!_saidOnce.add('$hand|$what')) return;
    _trace('hand $hand: $what');
  }

  final Set<String> _saidOnce = {};

  void _openHand() {
    played.clear();
    _saidOnce.clear();
    _botTurnSince.clear();
    _closedTurns.clear();
    step = 0;
    // The hand's jurors are the hand's to reach: a jury carried for an
    // earlier hand still serves until relieved, and a new one changes
    // who there is to dial.
    _reachOut();
    _proposeJury();
    if (spec.sealed) {
      _startDealWhenReady();
      return;
    }
    _openPlay();
  }

  /// The hand's cards are in: open the pass, or the first play.
  void _openPlay() {
    if (game.phase == Phase.passing) {
      // Every pass turn opens before any bot passes: a bot's pass closes
      // its turn and drains what was deferred, and a human's pass held
      // there has to find its turn open or it is lost.
      for (var s = 0; s < seatCount; s++) {
        _openTurn(TurnId.pass(game.handNumber, s), s, botActs: false);
      }
      for (var s = 0; s < seatCount; s++) {
        if (holders[s] is BotSeat) _botTurn(TurnId.pass(game.handNumber, s), s);
      }
    } else if (game.phase == Phase.playing) {
      _openPlayTurn();
    }
  }

  void _openPlayTurn() {
    final seat = game.currentSeat;
    if (seat == null) return;
    _openTurn(TurnId.play(game.handNumber, _playIndex), seat);
  }

  void _openTurn(TurnId turn, int seat, {bool botActs = true}) {
    if (_races.containsKey(turn)) return;
    _races[turn] = _Race();
    _openedAt[turn] = clock.nowMs;
    _turnSeat[turn] = seat;
    _trace('open $turn for seat $seat (${holders[seat]})');
    if (botActs && holders[seat] is BotSeat && _botActsHere(turn.hand, seat)) _botTurn(turn, seat);
  }

  /// The custodians a piece of [seat] is worth sealing to: the first
  /// few that could say its moves ([_sayers]), by their place in the
  /// escrow's own order. Every custodian holds a piece of its own, so
  /// one more opens the seat, and the side that has to open it is the
  /// one that will say the seat's moves — the first of this list
  /// ([_firstToSay]). The next two are there so that its going does
  /// not cost another round of releases.
  ///
  /// Said again every few seconds from a fresh reading, so a list
  /// drawn up when somebody was still being heard corrects itself.
  Set<int> _whoNeedsIt(int hand, int seat) {
    final order = _escrowOrder(hand, seat);
    const want = escrowThreshold + 1;
    final out = <int>{};
    for (final k in _sayers(hand, seat)) {
      if (out.length >= want) break;
      out.add(order.indexOf(k) + 1);
    }
    // And filled out from the order itself where too few are known to
    // be live, so that the count is always met. A juror hears the
    // table rather than its fellow jurors — it dials the seats and
    // they dial it, and the jury never dials itself ([_reachOut]) — so
    // its reading of which of them are about runs behind theirs, and
    // comes up short often enough that the fill is what the count
    // rests on rather than a safeguard against something rare. Sealed
    // to a custodian that has gone is a few bytes wasted; sealed to too
    // few is a seat the hand stops at.
    for (var i = 0; i < order.length && out.length < want; i++) {
      out.add(i + 1);
    }
    return out;
  }


  /// Whether this side is the one to say a given-up seat's moves: the
  /// first of the hand's custodians, in the escrow's own order, that
  /// is still being heard from ([_sayers]).
  bool _firstToSay(int hand, int seat) {
    final first = _sayers(hand, seat).firstOrNull;
    return first != null && first == signer.publicKey;
  }

  /// Who could say a given-up seat's moves, first first: the hand's
  /// custodians still heard from, in the escrow's own order — leaving
  /// the seat's own juror to last, since the escrow took the seat from
  /// it for being gone or slow, and keeping it only for when it is the
  /// one juror back.
  List<PublicKey> _sayers(int hand, int seat) {
    final live = _liveJurors(hand);
    final held = botHolders(hand)[seat];
    final order = _escrowOrder(hand, seat).where(live.contains).toList();
    return [...order.where((k) => k != held), ...order.where((k) => k == held)];
  }

  /// [seat]'s custodians in the escrow's own order: the list its keys
  /// named, grown on the record ([_applyGrowth]) — the order a sealed
  /// piece is addressed by. Before its keys are read here, the hand's
  /// jurors as this side has them.
  List<PublicKey> _escrowOrder(int hand, int seat) => _dealsByHand[hand]?.custodiansOf(seat) ?? _custodiansNow(hand);

  /// Whether [seat]'s bot moves are this side's to work out. A bot
  /// seat nobody holds is everyone's to compute. One a juror holds is
  /// that juror's alone: every other peer waits to be told
  /// (docs/04-live-play.md).
  ///
  /// Until it is given up to the escrow. A holder that goes quiet is a
  /// seat nobody is playing, and the pieces that open it go to every
  /// side that will ever hold its key — so the seat goes back to being
  /// everyone's to work out, as an unheld one always was. The named
  /// holder is still the one that may speak for it ([_mayAct]), so a
  /// juror that was only unheard for a while and comes back is not a
  /// liar: it says the same move every side worked out for itself.
  bool _botActsHere(int hand, int seat) {
    final holder = botHolders(hand)[seat];
    return holder == null || holder == signer.publicKey || (_deal?.gone.contains(seat) ?? false);
  }

  /// A bot's turn, taken once the stack is clear of the turn before
  /// it. A bot's move closes its turn, which opens the next, which may
  /// be a bot's too: run as a loop, a table of bots plays a whole game
  /// — a deserted table, a leaver's client looking on — in one call
  /// without the stack growing by a frame per card, which a browser's
  /// stack does not survive.
  void _botTurn(TurnId turn, int seat) {
    _botQueue.add((turn, seat));
    if (_runningBots) return;
    _runningBots = true;
    try {
      while (_botQueue.isNotEmpty && !_closed) {
        final (t, s) = _botQueue.removeAt(0);
        _botActs(t, s);
      }
    } finally {
      _runningBots = false;
    }
  }

  final List<(TurnId, int)> _botQueue = [];

  /// The turns of this hand closed here ([_closeTurn]). Not the same
  /// as settled: a departed person's turn is settled by the removal,
  /// and closed by the move its seat, a bot from there, still owes.
  final Set<TurnId> _closedTurns = {};
  bool _runningBots = false;

  /// A bot's turn: its move is a function of the deal and the record,
  /// computed here and settled at once. At a sealed table its deal
  /// steps are public work the session already did, and a departed
  /// person's seat cannot move until its secret is rebuilt from
  /// escrow — the turn stalls, settled or not, until the pieces come.
  void _botActs(TurnId turn, int seat) {
    final d = _deal;
    // A play the table has already moved past is not played again. A
    // seat given up to the escrow is worked out by every side, and its
    // own juror — back from whatever kept it quiet — may say the move
    // while this side is still waiting on the pieces: the stall that
    // resumes afterwards would otherwise put a second card down at
    // whatever turn is open by then. A turn settled and *not* moved
    // past is the ordinary way a booted seat's move is taken — the
    // removal settles the turn and the seat, a bot from there, still
    // owes the card that closes it.
    if (turn.isPlay && (turn.hand != game.handNumber || turn.playIndex != _playIndex)) return;
    // A seat this side holds for the jury: its move is nobody else's
    // to work out, so it is said and settles as a person's does. A
    // seat somebody else holds is not this side's business at all —
    // it has no hand to work from, and every way in here has to be
    // stopped, not only the turn being opened.
    if (!_botActsHere(turn.hand, seat)) return;
    // Said here, rather than worked out. A bot seat nobody holds is
    // everyone's to compute and needs no event. One the jury holds
    // has to be said, because no other side can work it out: by its
    // own juror, or — once the seat is given up and the escrow has
    // opened it — by whichever juror came by the key. Getting here at
    // all means this side is one of those two ([_botActsHere]), and a
    // player never does: its [_stall] above is where it waits, since
    // the pieces of a bot seat are sealed to the jury and it will
    // never hold the key.
    final heldHere = botHolders(turn.hand)[seat] != null;
    // A move is said by one juror, not by every juror that came by
    // the key. They all hold the same key and would all work out the
    // same card, so a jury's worth of copies of every trick would go
    // on the wire for nothing. The first of the hand's custodians
    // still being heard from says it, in the escrow's own order,
    // which needs no agreement: a custodian that goes quiet drops out
    // of that order everywhere and the next one is first. Until the
    // record gives the seat to the escrow, though, it is its own
    // juror's alone ([_carryEscrow]).
    //
    // Every side that will say nothing stops here — which is every
    // player, since a bot seat's pieces are sealed to the jury and no
    // player will ever hold its key. Not its deal steps and not its
    // audit, though: those are settled by each side for itself below,
    // with nothing said by anyone.
    if (heldHere && !turn.isDeal && !turn.isAudit) {
      // Nobody's here at all in a hand that was over before this side
      // was summoned ([_beforeSummons]).
      if (_beforeSummons(turn.hand)) return;
      // Its own juror until the record gives it to the escrow; then the
      // first of the escrow's jurors still heard, which is that same
      // juror only when it is the one back ([_sayers]).
      final holder = botHolders(turn.hand)[seat];
      if (_isEscrowed(turn.hand, seat) ? !_firstToSay(turn.hand, seat) : holder != signer.publicKey) return;
    }
    if (d != null) {
      if (d.awaitsSecret(seat)) return _stall(turn, seat);
      // Held for the game's end, which this side said at the turn
      // ([_holdsForEnding]): looked at again as the stalled are.
      if (_holdsForEnding(turn)) return _stall(turn, seat);
      if (turn.isDeal || turn.isAudit) {
        // A bot seat nobody holds has deal steps everyone computes, so
        // the turn settles here with nothing said. A held seat's are
        // its juror's to say, in _actOnDeal, like a person's.
        //
        // Except the audit of a seat given up to the escrow. Its
        // secret went out in the clear the moment the hand was over
        // ([_releaseFor]), so every side can check the hand for
        // itself and there is nothing left for anybody to say — and
        // nobody to say it: the juror that came by the key sits at
        // its own seat in the deal, not at this one, so an audit held
        // here would be an audit that never came.
        if (heldHere && !(turn.isAudit && d.gone.contains(seat))) return;
        // Nor a bot seat's keys before the record has said whether the
        // jury holds it: keys settled with nothing said cannot be
        // unsettled if the record then seals the hand to a draw that
        // holds the seat. Offered again once the record has said
        // ([_checkSealed]). Not a seat whose person left in
        // this hand: no jury holds that one, and its keys are the ones
        // anybody computes ([_botSeatsAt]).
        if (turn.isDeal && turn.dealRound == 0 && !_sealedTo.containsKey(turn.hand) && _botSeatsAt(turn.hand).contains(seat)) return;
        if (_closedTurns.contains(turn)) return;
        _races[turn]!.settled = true;
        _closeTurn(turn);
        return;
      }
      if (!game.knowsHand(seat)) {
        // A pass into this seat taken as unknown is opened first: a
        // seen hand takes what came in. One that will not open holds
        // the seat, as a secret still awaited does.
        if (!openPassInto(d, game, seat)) {
          _trace('seat $seat\'s hand waits: the pass into it is not open here');
          return _stall(turn, seat);
        }
        // As the engine holds it: the hand as dealt while the pass is
        // unresolved, since the deal moves positions as each pass
        // settles and the engine only when all four have.
        final cards = game.phase == Phase.playing ? d.handOf(seat) : d.dealtHandOf(seat);
        if (cards == null) {
          // Open in the deal and still not whole: three of it came in
          // on a pass that will not open (docs/03-fair-deal.md), and
          // the engine cannot be given a hand with holes in it. The
          // turn waits, as it does for a secret.
          _trace('seat $seat\'s hand waits: it is not whole here yet');
          return _stall(turn, seat);
        }
        game.revealHand(seat, [for (final i in cards) Card.deck[i]]);
      }
    }
    final bot = Bot(persona: (holders[seat] as BotSeat).persona);
    if (turn.isPass) {
      final cards = bot.choosePass(game.handOf(seat));
      if (heldHere) return sayPass(seat, cards);
      if (d != null) {
        final to = (seat + game.passDirection.seatOffset) % seatCount;
        d.passOpen(seat, to, [for (final c in cards) d.positionOf(seat, c.index)!]);
        _declareLead();
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
      if (heldHere) return sayPlay(seat, card);
      if (d != null) d.playOpen(seat, d.positionOf(seat, card.index)!);
      game.play(seat, card);
      played.add(card);
    }
    _races[turn]!.settled = true;
    _closeTurn(turn);
  }

  /// After a turn settles: sweep, deal, and open what is next.
  void _closeTurn(TurnId turn) {
    _closedTurns.add(turn);
    step++;
    _myWitness.remove(turn);
    if (turn.isDeal) {
      _advanceDeal();
      _drainFuture();
      _actOnDeal();
      _notify();
      return;
    }
    if (turn.isAudit) {
      if (_openingAudit) {
        if (_auditsIn) _giveUpHand();
      } else if (_auditDone && game.phase == Phase.handOver) {
        _finishHand();
      }
      _drainFuture();
      _actOnDeal();
      _notify();
      return;
    }
    if (game.phase == Phase.passing) {
      // Waits for every seat's pass; the next turns open with play.
      _drainFuture();
      return;
    }
    if (game.pendingTrick != null) game.collectTrick();
    if (game.phase == Phase.handOver || game.phase == Phase.gameOver) {
      if (spec.sealed) {
        // Every person reveals its deal secret before the next deal —
        // and after the last — so the hand can be checked by anyone.
        for (var s = 0; s < seatCount; s++) {
          _openTurn(TurnId.audit(game.handNumber, s), s);
        }
        _sayOpenReleases();
        _actOnDeal();
      } else if (game.phase == Phase.handOver) {
        _finishHand();
      }
    } else if (game.phase == Phase.playing) {
      _openPlayTurn();
    }
    _drainFuture();
    _notify();
  }

  /// The hand is over and, at a sealed table, audited: on to the next
  /// deal. The table does not wait on anyone to look at the score
  /// sheet; a view that wants to show it takes it from here.
  void _finishHand() {
    _handEnds[game.handNumber] = HandState.over;
    lastHand = (
      hand: game.handNumber,
      scores: game.handScores,
      totals: game.totals,
      moonShooter: game.moonShooter,
    );
    game.nextHand();
    _openHand();
  }

  /// Every audit turn settled — and none of them stalled: a seat
  /// removed at its audit is audited by the escrow, whose pieces have
  /// to come before the hand can close, or the record could never open
  /// its cards.
  bool get _auditDone => _auditsIn && !_stalled.keys.any((t) => t.hand == game.handNumber);

  /// Every audit turn settled, and none of them stalled. What a hand
  /// being given up waits for: a turn of it stalled on a hand that will
  /// never open is the reason it is being given up, so it is not a
  /// reason to wait.
  bool get _auditsIn =>
      Iterable<int>.generate(seatCount).every((s) => _races[TurnId.audit(game.handNumber, s)]?.settled == true) &&
      !_stalled.keys.any((t) => t.hand == game.handNumber && t.isAudit);

  TurnId? _openTurnOf(int seat) {
    for (final e in _races.entries) {
      if (!e.value.settled && _turnSeat[e.key] == seat) return e.key;
    }
    return null;
  }

  // ---- receiving --------------------------------------------------------

  void _onMessage(PublicKey from, Map<String, Object?> json) {
    if (_closed) return;
    if (_failure != null) return _answerEnded(json);
    // An event seen before was checked before; the same id is the
    // same bytes, and a signature checked again is milliseconds a peer
    // being repeated at has not got.
    final seen = _seen.contains(json['id']);
    final event = TableEvent.parse(json, verifySignature: !seen);
    if (event == null || event.table != spec.id) return;
    // Hearing is direct: whoever delivered this is here now.
    _lastHeard[from] = clock.nowMs;
    // And an event this peer has never seen, by someone else, made at
    // or after where this peer stands, is that author's own work at
    // this peer's level: they were here for it. Peers relay each
    // other's events when catching someone up, and a relayed copy of
    // something already seen says nothing — the commonest thing
    // re-sent is a departed seat's last play — but without it a table
    // where only some peers hear a seat directly (one relay socket gone
    // quiet, one WebRTC channel of three) splits at that seat's turn,
    // the deaf peers booting it while the others witness its play.
    // Not while this peer is itself behind and being carried forward:
    // then the work arriving is the table's past, however new to this
    // peer, and no sign that its author is still here.
    if (event.author != from && _humans.contains(event.author) && !_seen.contains(event.id) && !_alreadyPast(event) && !_behind) {
      _lastHeard[event.author] = clock.nowMs;
    }
    if (event.kind == EventKind.serve) {
      // A juror's heartbeat: it says where the juror stands, and a
      // juror is carried forward like anyone, since it has to hold the
      // table's present to judge it.
      if (event.author != from) return;
      _noteReads(event);
      _jurorHeard[from] = clock.nowMs;
      _notePosition(from, event.hand, event.step);
      _carryForward(from, event.hand, event.step);
      return;
    }
    if (event.kind == EventKind.heartbeat) {
      if (event.author != from) return;
      _noteReads(event);
      if (!_isParticipant(from)) {
        // A seat removed from the table, still sending: it is behind
        // for good, and what it needs is the turns up to the one that
        // removed it, so that it learns so in order — and no more, and
        // not often, or every peer would answer its every heartbeat
        // with the whole record, for ever.
        final last = _lastTold[from];
        if (last != null && clock.nowMs - last < 10000) return;
        _lastTold[from] = clock.nowMs;
        _carryForward(from, event.hand, event.step, upTo: _removedAt[from]);
        return;
      }
      _notePosition(from, event.hand, event.step);
      _carryForward(from, event.hand, event.step);
      return;
    }
    if (_seen.contains(event.id)) {
      // Seen before, and sent again: the sender is still waiting on a
      // turn this peer may have settled. Answer with what settled it.
      // A jury proposal sent again is the same proposal — the leader
      // says it every few seconds until it carries — and a peer that
      // could not back it before, its presence not yet having seen
      // the jurors, looks again.
      if (event.kind == EventKind.jury) return _reconsiderJury(event);
      // An appeal said again is the same appeal, and it still stands
      // ([appealStandsMs]).
      if (event.kind == EventKind.appeal && _appealSeenAt.containsKey(event.turn) && _isParticipant(event.author)) {
        _appealHeardAt[event.turn] = clock.nowMs;
      }
      if (event.kind != EventKind.leave && event.kind != EventKind.release && event.kind != EventKind.topup) _catchUp(event.turn);
      return;
    }
    _accept(event);
    _notify();
  }

  /// A heartbeat, a person's or a juror's, says what its sender reads;
  /// the transport picks where to write from that (transport.dart).
  void _noteReads(TableEvent event) {
    final reads = event.body['reads'];
    if (reads is List) transport.heard(event.author, reads.whereType<String>().toList());
  }

  /// Whether [event] is about a position this peer has already passed.
  bool _alreadyPast(TableEvent event) {
    if (event.kind == EventKind.heartbeat || event.kind == EventKind.serve) {
      return event.hand < game.handNumber || (event.hand == game.handNumber && event.step < step);
    }
    if (event.kind == EventKind.release || event.kind == EventKind.topup) return event.hand < game.handNumber;
    final t = event.turn;
    if (t.hand != game.handNumber) return t.hand < game.handNumber;
    return t.position < _herePosition;
  }

  void _onDisconnected(PublicKey key) {
    // A closed connection is silence the transport is sure of, so most
    // of the allowance is already spent — all but [reloadGraceMs]: a
    // page reloaded closes its connection too, and comes back to its
    // seat from its journal (journal.dart) if it is still its seat.
    if (_humans.contains(key)) {
      _lastHeard[key] = clock.nowMs - silenceAfterMs + min(reloadGraceMs, silenceAfterMs);
    }
  }

  /// How long a seat whose connection closed has to come back before
  /// it counts as silent: a page reloaded, the app started again. Less
  /// than the turn's own clock, so a device really gone holds the table
  /// up for no longer than one that is there and slow.
  static const reloadGraceMs = 20000;

  void _accept(TableEvent event) {
    if (!_seen.add(event.id)) return;
    switch (event.kind) {
      case EventKind.heartbeat:
        return;
      case EventKind.witness:
        _onWitness(event);
      case EventKind.pass:
      case EventKind.play:
      case EventKind.deal:
        _onAction(event);
      case EventKind.release:
        _onRelease(event);
      case EventKind.topup:
        _onTopUp(event);
      case EventKind.boot:
      case EventKind.absent:
        _onBoot(event);
      case EventKind.escrow:
        _onEscrow(event);
      case EventKind.leave:
        _onLeave(event);
      case EventKind.jury:
        _onJury(event);
      case EventKind.serve:
        _jurorHeard[event.author] = clock.nowMs;
      case EventKind.appeal:
        _onAppeal(event);
      case EventKind.verdict:
        _onVerdict(event);
      case EventKind.ended:
        _onEndedClaim(event);
    }
  }

  /// [quietly] for a step waiting on nothing but this side's own deal
  /// worker, which every step of every deal does for a moment.
  void _defer(TableEvent event, {bool quietly = false}) {
    // Once each: a peer far behind is repeated at for minutes, and the
    // list is drained at every turn that closes.
    if (!_futureIds.add(event.id)) return;
    _future.add(event);
    if (!quietly && event.kind != EventKind.witness && event.kind != EventKind.release && event.kind != EventKind.topup) {
      _trace('defer ${event.kind.name}@${event.turn} from ${event.author.substring(0, 4)}');
    }
  }

  final Set<String> _futureIds = {};

  void _drainFuture() {
    if (_future.isEmpty) return;
    final again = List.of(_future);
    _future.clear();
    _futureIds.clear();
    // One that throws does not cost the rest: each is taken up on its
    // own, a failure is traced and then thrown once they all have been,
    // as it would have been had it arrived just now.
    (Object, StackTrace)? failed;
    for (final e in again) {
      // Seen, until it is taken up here: the copy held is the event
      // itself, so a repeat of it is not read afresh, and does not cost
      // another signature check — a peer far behind holds hundreds of
      // them, and would pay for all of them at every carry.
      _seen.remove(e.id);
      try {
        _accept(e);
      } catch (error, stack) {
        // Not seen, so that the same event said again is read again.
        _seen.remove(e.id);
        _trace('held ${e.kind.name} ${e.id.substring(0, 6)} failed: $error');
        failed ??= (error, stack);
      }
    }
    if (failed != null) Error.throwWithStackTrace(failed.$1, failed.$2);
  }

  bool _isParticipant(PublicKey key) => _humans.contains(key) && !_removedAt.containsKey(key);

  /// A peer sending evidence for a turn settled here is behind — it
  /// missed what settled it. Send the decision and this peer's witness.
  final Map<TurnId, int> _lastCatchUp = {};

  /// A heartbeat that puts its sender behind this peer: send it what it
  /// is missing, a window at a time, so a peer back from a blip is
  /// carried forward without having to say anything first.
  void _carryForward(PublicKey asker, int hand, int step, {TurnId? upTo}) {
    if (hand > game.handNumber || (hand == game.handNumber && step >= this.step)) {
      _behindSince.remove(asker);
      return;
    }
    if (upTo != null && (hand > upTo.hand || (hand == upTo.hand && step > _stepOf(upTo)))) return;
    // One answer is enough: the lowest key among the live participants
    // answers a heartbeat at once, the others only once the asker has
    // stayed behind through a couple more — three peers answering the
    // same heartbeat with the same turns is three times the traffic.
    _behindSince.putIfAbsent(asker, () => clock.nowMs);
    // Not counting the asker, which cannot carry itself: where its key
    // is the lowest, nobody would be first, and every peer would wait
    // out the couple of heartbeats meant for the second in line.
    final live = participants.where((k) => k != asker && (k == signer.publicKey || _recent(k))).toList()..sort();
    // A juror is no participant: it answers once the participants have
    // had their turn to, or at once when it hears none of them.
    final first = live.isEmpty ? null : live.first;
    if (first != signer.publicKey && clock.nowMs - _behindSince[asker]! < heartbeatMs * 2 + 1000) return;
    var h = hand;
    var st = step;
    for (var n = 0; n < carryWindow; n++) {
      if (h > game.handNumber || (h == game.handNumber && st >= this.step)) return;
      final turn = _turnAtStep(h, st);
      if (upTo != null && (h > upTo.hand || (h == upTo.hand && turn.position > upTo.position))) return;
      _catchUp(turn);
      st++;
      if (st >= _stepsPerHand(h)) {
        h++;
        st = 0;
      }
    }
  }

  // ---- the hand's steps ----------------------------------------------
  //
  // A hand is a run of turns, counted in heartbeats as steps: at a
  // sealed table sixteen of the deal, then the passes (four, or none
  // on a hold hand), fifty-two plays, and four of the audit; at a
  // seeded one the passes and the plays alone.

  int get _dealSteps => spec.sealed ? TurnId.dealRounds * seatCount : 0;
  int _passSteps(int hand) => PassDirection.forHand(hand) == PassDirection.hold ? 0 : TurnId.passTurns;
  int get _auditSteps => spec.sealed ? seatCount : 0;
  int _stepsPerHand(int hand) => _dealSteps + _passSteps(hand) + TurnId.plays + _auditSteps;

  /// The turn at step [st] of [hand].
  TurnId _turnAtStep(int hand, int st) {
    if (st < _dealSteps) return TurnId.deal(hand, st ~/ seatCount, st % seatCount);
    st -= _dealSteps;
    final passes = _passSteps(hand);
    if (st < passes) return TurnId.pass(hand, st);
    st -= passes;
    if (st < TurnId.plays) return TurnId.play(hand, st);
    return TurnId.audit(hand, st - TurnId.plays);
  }

  /// Turns handed over per heartbeat to a peer behind.
  static const carryWindow = 12;

  /// When each peer was first seen behind, for the turn-taking above.
  final Map<PublicKey, int> _behindSince = {};

  /// The hand is over, so every secret the escrow is still holding
  /// sealed to the jury goes out in the open — once, and at the
  /// moment the audit opens rather than at the next tick, because a
  /// side that can settle the audit itself closes the hand and moves
  /// on inside the same breath and would never think to say them.
  /// Without this the players wait at the audit for a piece nobody is
  /// going to send: no player holds one of a bot seat, and no player
  /// ever will.
  void _sayOpenReleases() {
    final d = _deal;
    if (d == null) return;
    for (final seat in d.gone) {
      if (_saidOpen.add('${game.handNumber}|$seat')) _releaseFor(seat);
    }
  }

  /// Seats whose secret has been said in the open, by hand, so that
  /// the once it is owed is said once.
  final Set<String> _saidOpen = {};

  /// When each removed seat was last carried forward.
  final Map<PublicKey, int> _lastTold = {};

  /// A turn's position in the hand's step count: the first step of
  /// its set, for the concurrent ones.
  int _stepOf(TurnId t) {
    if (t.isDeal) return t.dealRound * seatCount + t.dealSeat;
    final passes = _passSteps(t.hand);
    if (t.isPass) return _dealSteps;
    if (t.isPlay) return _dealSteps + passes + t.playIndex;
    return _dealSteps + passes + TurnId.plays + t.auditSeat;
  }

  /// The turns that share [turn]'s position: the four of a deal
  /// round, of the pass, of the audit; a play alone.
  List<TurnId> _setOf(TurnId turn) {
    if (turn.isDeal) return [for (var s = 0; s < seatCount; s++) TurnId.deal(turn.hand, turn.dealRound, s)];
    if (turn.isPass) return [for (var s = 0; s < seatCount; s++) TurnId.pass(turn.hand, s)];
    if (turn.isAudit) return [for (var s = 0; s < seatCount; s++) TurnId.audit(turn.hand, s)];
    return [turn];
  }

  void _catchUp(TurnId turn) {
    // The turns of a set are concurrent; a peer behind at one needs
    // all of them, and they count as one for the limit.
    final turns = _setOf(turn);
    final settled = turns.where((t) => _races[t]?.settled == true).toList();
    // Nothing settled there, nothing to send — except in a hand this
    // side gave up in its deal. The turn that hand stopped at never
    // settles, nor any after it, and a peer still at one of them needs
    // what decided the hand, which is the escrow that gave it up: the
    // removals below. Sent nothing, it would wait there for good while
    // the table dealt on (undealt_hand_test.dart).
    if (settled.isEmpty && _handEnds[turn.hand] != HandState.abandoned) return;
    // Once a couple of seconds per turn, whoever is asking: a peer far
    // behind repeats a lot, and every answer is itself repeated evidence
    // to everyone else.
    final key = turns.first;
    final last = _lastCatchUp[key];
    if (last != null && clock.nowMs - last < 2000) return;
    // And a budget over all turns, in events: a peer far behind asks
    // about a window of them per heartbeat, and each answer is several
    // events. Unbudgeted, peers carrying others forward flood the
    // relay. Refilled at a few a second; what is not sent now is asked
    // for again on the next heartbeat.
    _refillCatchUp();
    if (_catchUpTokens < 1) return;
    _lastCatchUp[key] = clock.nowMs;
    // Everything that decided these positions, and every departure in
    // the record wherever it sits: a removal the asker missed is the
    // commonest reason to be stuck, and it may have been made at a turn
    // the asker has long settled — a leave is placed where the leaver
    // stood, not where the table noticed.
    for (final d in record) {
      if (d.removal || settled.contains(d.turn)) _send(d.event.toJson());
    }
    // And the pieces released for any seat gone this hand: a peer
    // behind cannot play the seat's bot without them.
    for (final r in _releases[turn.hand] ?? const <TableEvent>[]) {
      _send(r.toJson());
    }
    // And the parts of a share made for a juror brought on: the one
    // peer that most needs them is the one furthest behind.
    for (final r in _topUps[turn.hand] ?? const <TableEvent>[]) {
      _send(r.toJson());
    }
    for (final t in settled) {
      _sendEvidence(t);
    }
    for (final d in record) {
      if (d.removal && !settled.contains(d.turn)) _sendEvidence(d.turn);
    }
    // And every leave with its backing, carried or not: the leaver has
    // gone, and a peer that missed it has nobody else to hear it from.
    for (final c in _leaves.values) {
      _send(c.event.toJson());
      for (final w in c.witnessEvents) {
        _send(w.toJson());
      }
    }
    // A turn the jury settled travels with its verdict: the votes alone
    // never made a majority, so the votes alone would leave the asker
    // where the table was stuck.
    for (final d in record) {
      if (d.verdict != null && (d.removal || settled.contains(d.turn))) _send(d.verdict!.toJson());
    }
    // And the juries, which a verdict in any of that rests on.
    for (final d in juries) {
      _send(d.event.toJson());
      for (final w in _proposals[d.event.id]?.witnessEvents ?? const <TableEvent>[]) {
        _send(w.toJson());
      }
    }
  }

  /// One catch-up event, if the budget has it and it has not just
  /// been said.
  ///
  /// A carry is a broadcast: it goes to everyone, so saying the same
  /// event again a moment later carries nobody any further forward and
  /// costs the table a copy per peer. A window is twelve turns, and
  /// each of them wants every departure in the record, every jury and
  /// every one of the jury's witnesses. So an event goes at most once
  /// per [carryRepeatMs], whoever is asking and however many turns want
  /// it; a peer that missed it asks again and gets it after that, and
  /// the budget goes on turns the asker has not seen at all.
  void _send(Map<String, Object?> json) {
    final id = json['id'];
    if (id is String && clock.nowMs - (_saidAgainAt[id] ?? -carryRepeatMs) < carryRepeatMs) return;
    _refillCatchUp();
    if (_catchUpTokens < 1) return;
    _catchUpTokens -= 1;
    if (id is String) _saidAgainAt[id] = clock.nowMs;
    transport.broadcast(json);
  }

  /// When each event was last said again for somebody behind.
  final Map<String, int> _saidAgainAt = {};

  /// How long an event stays said. Measured rather than picked: at a
  /// jury of six a hand says 349,305 bytes at five seconds and 269,961
  /// at eight, and eight is the knee — twelve buys nothing more
  /// (`tool/wire_in_sim.dart`). It has to be longer than the two
  /// seconds a turn waits between carries, so a window's worth of
  /// turns asking for the same jury gets one copy of it, and what it
  /// costs is the wait after a carry that goes missing.
  static const carryRepeatMs = 8000;

  /// Forgets what has gone stale, so the memory is the last few
  /// seconds and not the table's whole history.
  void _forgetSaidAgain() {
    if (_saidAgainAt.length < 256) return;
    final now = clock.nowMs;
    _saidAgainAt.removeWhere((_, at) => now - at >= carryRepeatMs);
  }

  /// Catch-up events in hand, refilled at [catchUpPerSecond] up to
  /// [catchUpBurst].
  double _catchUpTokens = catchUpBurst.toDouble();
  int _catchUpRefilledAt = 0;
  // Sized for the sealed table, where a juror summoned mid-hand has to
  // be current before a departed seat's hand can be opened with its
  // piece: a hand is some eighty turns of four or five events each,
  // and at half this rate that is a minute and a half of everyone
  // waiting.
  static const catchUpPerSecond = 24;
  static const catchUpBurst = 96;

  void _refillCatchUp() {
    final now = clock.nowMs;
    if (_catchUpRefilledAt == 0) _catchUpRefilledAt = now;
    _catchUpTokens = (_catchUpTokens + (now - _catchUpRefilledAt) * catchUpPerSecond / 1000).clamp(0, catchUpBurst).toDouble();
    _catchUpRefilledAt = now;
  }

  /// How long somebody has to have been announcing to count as
  /// settled for the draw. A minute: long enough that it is evidence
  /// of anything, short enough that a table forming in a quiet room
  /// does not wait on it — and where nobody clears it, the draw falls
  /// back to whoever is there.
  static const jurySettledMs = 60000;

  /// The claims and witnesses this peer holds for [turn].
  void _sendEvidence(TurnId turn) {
    final race = _races[turn];
    if (race != null) {
      for (final b in race.boots) {
        _send(b.toJson());
      }
      for (final w in race.witnessEvents) {
        _send(w.toJson());
      }
      final mine = _myWitnessEvents[turn];
      if (mine != null && !race.witnessEvents.contains(mine)) _send(mine.toJson());
    }
  }

  /// A juror hears both sides of a table cut in two. From the first
  /// appeal of a hand to the end of it, the first juror in the draw
  /// still heard from says again, at once, everything it hears for a
  /// turn not yet settled, so the votes cross the cut and the table
  /// runs at its own pace rather than an appeal's. One juror carries,
  /// not four: a shared relay sees each event twice, not five times.
  void _relayIfAppealed(TableEvent event) {
    if (mySeat != null || _carryingHand != game.handNumber) return;
    final order = _orderFor(game.handNumber);
    final carrier = order.where((j) => j == signer.publicKey || _jurorRecent(j)).firstOrNull;
    if (carrier != signer.publicKey) return;
    try {
      final turn = event.turn;
      if (_races[turn]?.settled == true) return;
      transport.broadcast(event.toJson());
    } catch (_) {}
  }

  /// The hand in which this juror last heard an appeal.
  int _carryingHand = -1;

  bool _jurorRecent(PublicKey j) => clock.nowMs - (_jurorHeard[j] ?? _never) < timing.jurorSilenceMs;

  void _onAction(TableEvent event) {
    _relayIfAppealed(event);
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    final race = _races[turn];
    if (race == null) return _defer(event); // current, and not open yet
    if (race.settled) return _catchUp(turn);
    final seat = _turnSeat[turn]!;
    if (_isEscrowedAudit(turn, seat)) return;
    if (!_mayAct(seat, event.author, turn.hand)) {
      // For a bot seat's deal step, as below: a judgement about what
      // this side knows rather than about the event. Who may act for
      // a bot seat is any juror of the hand ([_mayAct]), and a juror
      // brought on mid-hand reads the hand's juries the wrong way
      // round — the redraw that summoned it before the draw the seats
      // were dealt to — so the seat's true holder is a stranger here
      // for a moment and its step arrives before the jury that says
      // otherwise. Kept for the drain: dropped, its id would stay seen
      // and every copy said again read as the sender being behind, so
      // the seat's keys would never arrive here.
      //
      // A person's seat is not this: who may act for it is its own
      // key and nothing this side learns later changes that.
      if (event.kind == EventKind.deal && holders[seat] is! HumanSeat) return _defer(event);
      // Nor is a held seat's move by one of the escrow's jurors, where
      // this side has yet to see the escrow the table carried: it comes
      // with the move, or a moment after ([_carryEscrow]). Kept for
      // when it does, rather than taken as the seat's and settling the
      // turn with no escrow in this side's record.
      final held = botHolders(turn.hand)[seat];
      if (held != null && event.author != held && !_isEscrowed(turn.hand, seat)) return _defer(event);
      return;
    }
    if (!_checkable(event)) {
      // Checked once the check has been made elsewhere, and kept for
      // the drain that follows it back, like any step waiting on
      // something this side does not have yet (below).
      return _defer(event, quietly: true);
    }
    if (!_valid(event, seat)) {
      // Not valid *here, now*, which is not the same as wrong. A deal
      // step is checked against things this side may not have yet:
      // round 0 names the custodians it sealed to and is refused
      // until they have all been seen proposed ([_validDeal]), and a
      // juror hears a hand's jury a moment after the table does. So
      // it is kept and looked at again whenever that changes
      // ([_drainFuture]) rather than dropped: dropped, the only way
      // back to it is somebody saying it again, which the carry window
      // holds off for [carryRepeatMs].
      //
      // Only a deal step, and only while its turn is still open: a
      // play or a pass that does not check out is wrong rather than
      // early, and a turn that settles some other way takes the held
      // copy with it at the next drain.
      if (event.kind == EventKind.deal) return _defer(event);
      _seen.remove(event.id);
      return;
    }
    if (race.action != null && race.action!.id != event.id) {
      // Equivocation at a person's seat: the first stands. At a bot seat
      // a second voice is allowed — its juror back from being late, a
      // custodian the table gave the seat to meanwhile — and each peer
      // witnesses whichever it heard first; the other is kept with its
      // witnesses, so that the one a majority backs is the one every
      // side ends on, or the jury picks when none can ([_settle]).
      if (holders[seat] is BotSeat) {
        race.rivals[event.id] = event;
        race.forRival.putIfAbsent(event.id, () => {})
          ..add(event.author)
          ..addAll(_earlyWitnesses.remove(event.id) ?? const {});
        race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
        _settle(turn);
      }
      return;
    }
    race.action = event;
    race.forAction.add(event.author);
    race.forAction.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    // Witness the action unless this peer already backed the boot.
    if (amSeated && event.author != signer.publicKey && !_myWitness.containsKey(turn)) {
      _witness(turn, event);
    }
    _settle(turn);
  }

  /// Whether an action is one this peer will back: legal under the
  /// engine, and at a sealed table verified by the deal. This peer's
  /// own actions were made from its own state and are not re-checked.
  bool _valid(TableEvent event, int seat) {
    try {
      if (event.author == signer.publicKey) return true;
      if (event.kind == EventKind.deal) return _validDeal(event, seat);
      if (event.kind == EventKind.pass) {
        if (game.phase != Phase.passing || game.hasPassed(seat)) return false;
        final d = _deal;
        if (d != null) {
          final b = Map<String, Object?>.from(event.body);
          if ((b['positions'] as List).length != passSize) return false;
          if (b['from'] != seat || b['to'] != (seat + game.passDirection.seatOffset) % seatCount) return false;
          return d.verifyPass(b);
        }
        final cards = [for (final c in event.body['cards'] as List) Card.parse(c as String)];
        if (cards.length != passSize || cards.toSet().length != passSize) return false;
        return cards.every(game.handOf(seat).contains);
      }
      if (event.kind != EventKind.play) return false;
      if (game.phase != Phase.playing || game.currentSeat != seat) return false;
      final card = Card.parse(event.body['card'] as String);
      final d = _deal;
      if (d != null) {
        return d.verifyPlay(seat, Map<String, Object?>.from(event.body)) == card.index && game.allows(seat, card);
      }
      return game.legalPlaysFor(seat).contains(card);
    } catch (_) {
      return false;
    }
  }

  /// A step of the deal: the turn's round and seat, and the session's
  /// check of the step itself. Keys may only escrow to jurors this
  /// peer has seen proposed at this table: a seat naming a key nobody
  /// can reach would leave its hand unopenable when it left.
  bool _validDeal(TableEvent e, int seat) {
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
        if (!_keysNameTheDraw(e, seat)) return false;
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

  /// A boot, by the clock or for silence: a vote against the seat's
  /// action in the race for its turn.
  void _onBoot(TableEvent event) {
    _relayIfAppealed(event);
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    final race = _races[turn];
    if (race == null) return _defer(event); // current, and not open yet
    if (race.settled) return _catchUp(turn);
    final seat = _turnSeat[turn]!;
    if (event.seat != seat) return;
    if (!_isParticipant(event.author)) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key == event.author) return;
    race.boots.add(event);
    race.forRemoval.add(event.author);
    race.forRemoval.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    if (event.author == signer.publicKey) {
      _myWitness[turn] = event.id; // a side taken
      _bootBacked[holder.key] = turn;
    } else {
      _considerCountersigning(turn, event);
    }
    _settle(turn);
  }

  /// A claim that a held bot seat's juror is out at the seat's turn:
  /// not heard from for half a minute, or past its allowance on the
  /// turn ([_outOfTime]), by the clock of the person making it. A vote
  /// against the juror's move in the race for the turn, as a boot is
  /// against a person's, carried the same way — by the people at the
  /// table, or where they cannot, by the jury ([_judge]) — and what it
  /// carries is the seat, to the escrow, for the rest of the hand
  /// ([_carryEscrow]).
  void _onEscrow(TableEvent event) {
    _relayIfAppealed(event);
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    final race = _races[turn];
    if (where < 0 || (race?.settled ?? false)) {
      if (_lateEscrowAt(turn) && event.seat == _turnSeat[turn] && _participantsAt(turn).contains(event.author)) {
        _takeLateClaim(turn, event);
      }
      return _catchUp(turn);
    }
    if (race == null) return _defer(event); // current, and not open yet
    // Nor a seat at its keys the record has not yet said is held: which
    // seats a jury holds, and whose, is the draw the deal is sealed to
    // ([_checkSealed]).
    if (turn.isDeal && turn.dealRound == 0 && !_sealedTo.containsKey(turn.hand)) return _defer(event);
    final seat = _turnSeat[turn]!;
    if (event.seat != seat || !_isParticipant(event.author)) return;
    if (botHolders(turn.hand)[seat] == null || _isEscrowed(turn.hand, seat)) return;
    race.boots.add(event);
    race.forRemoval.add(event.author);
    race.forRemoval.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    if (event.author == signer.publicKey) {
      _myWitness[turn] = event.id; // a side taken
    } else {
      _considerCountersigning(turn, event);
    }
    _settle(turn);
  }

  /// The held seats given to the escrow on the record, by hand, with
  /// the turn each was given up at.
  final Map<int, Map<int, TurnId>> _escrowed = {};

  bool _isEscrowed(int hand, int seat) => _escrowed[hand]?.containsKey(seat) ?? false;

  /// The held seats of [hand] the record has given to the escrow, and
  /// the turn each went at.
  Map<int, TurnId> escrowedAt(int hand) => Map.unmodifiable(_escrowed[hand] ?? const {});

  /// Whether [turn] is the audit of a seat the record has given to the
  /// escrow. That audit is its pieces, said in the open at the hand's
  /// end, and every side closes the turn from them with nothing said
  /// ([_botActs]). Its juror's own audit is not a move there: taken at
  /// a side still waiting for the pieces and witnessed, it would carry
  /// where the rest had closed the turn silently, and the records
  /// would differ. So its juror does not say it ([_actOnDeal]), and
  /// one said anyway — before the juror knew — is not taken.
  bool _isEscrowedAudit(TurnId turn, int seat) => turn.isAudit && _isEscrowed(turn.hand, seat);

  /// Whether a claim for the escrow at [turn] is still to be taken here
  /// although the turn has settled here by the seat's move.
  ///
  /// The record elsewhere can hold both at one turn: the escrow carried,
  /// the turn opened again, and the people backing a move — the seat's
  /// own juror's, said before it knew, or the escrow's. A side carried
  /// in behind, or one that heard the backing for the move before the
  /// claims, settles the move first; the claims then arrive at a turn
  /// that is over. Dropped, that side would hold the seat as its
  /// juror's for the rest of the hand, where every other side holds it
  /// as the escrow's, and take none of the escrow's moves. So they are
  /// still taken, and the escrow recorded once a majority is seen
  /// behind it, or the jury's ruling ([_settleLateEscrow]). Only at a
  /// play or a pass: at a deal step the escrow ends the hand, and at an
  /// audit nothing is moved after it, so neither holds both.
  bool _lateEscrowAt(TurnId turn) {
    final seat = _turnSeat[turn];
    if (seat == null || !(turn.isPlay || turn.isPass)) return false;
    if (_races[turn]?.settled != true) return false;
    return botHolders(turn.hand)[seat] != null && !_isEscrowed(turn.hand, seat);
  }

  void _takeLateClaim(TurnId turn, TableEvent claim) {
    final race = _races[turn]!;
    if (!race.boots.any((b) => b.id == claim.id)) race.boots.add(claim);
    race.forRemoval.add(claim.author);
    race.forRemoval.addAll(_earlyWitnesses.remove(claim.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(claim.id) ?? const []);
    _settleLateEscrow(turn);
  }

  /// The escrow at [turn], carried elsewhere and settled here by the
  /// seat's move first: recorded beside the move, and the seat the
  /// escrow's from there, as at every other side ([_lateEscrowAt]).
  /// Nothing opens again: the move stands, as it does on their records.
  void _settleLateEscrow(TurnId turn, {TableEvent? verdict}) {
    final race = _races[turn]!;
    final of = _participantsAt(turn);
    if (verdict == null && race.forRemoval.intersection(of).length < _majority(of)) return;
    final seat = _turnSeat[turn]!;
    final hand = turn.hand;
    final claim = verdict?.ruled ?? race.boots.first;
    _log(Decision(
      turn: turn,
      event: claim,
      witnesses: {...race.forRemoval, if (verdict != null) verdict.author},
      removal: true,
      among: of,
      verdict: verdict,
    ));
    _trace('bot seat $seat to the escrow at $turn, carried there after its move had settled here');
    _escrowed.putIfAbsent(hand, () => {})[seat] = turn;
    final holder = botHolders(hand)[seat];
    if (holder != null && _liveJurors(hand).contains(holder)) _letGo.add(holder);
    // And its audit, if the hand has come that far here, is the pieces'
    // now and nobody's move ([_isEscrowedAudit]): one said there by the
    // seat's own juror before it knew goes, as it does where the escrow
    // is carried at the audit itself ([_carryEscrow]).
    final audit = TurnId.audit(hand, seat);
    final atAudit = _races[audit];
    if (atAudit != null && !atAudit.settled) {
      atAudit
        ..action = null
        ..forAction.clear()
        ..rivals.clear()
        ..forRival.clear();
      _myWitness.remove(audit);
      _myWitnessEvents.remove(audit);
    }
    if (hand == game.handNumber) {
      final d = _deal;
      if (d != null) {
        d.seatLeft(seat);
        _releaseFor(seat);
      }
      _drainFuture();
      _takeUpSeat(seat);
    }
    _notify();
  }

  /// Whether a held seat's juror is out, by this side's clocks: not
  /// heard from for half a minute, or past its allowance on the turn
  /// in front of it ([_outOfTime]).
  bool _jurorOut(int seat) {
    final holder = botHolders(game.handNumber)[seat];
    if (holder == null) return false;
    return !_liveJurors(game.handNumber).contains(holder) || _outOfTime(seat);
  }

  /// Said again by every path, when someone claims this seat is not
  /// here: its action for [turn] if it has one, else a heartbeat. A
  /// boot, a claim of absence or an appeal against this seat means
  /// the one making it did not hear this device — most likely it
  /// cannot read the relay this device writes to — and the one way to
  /// be heard is to say it where they read. At most once in five
  /// seconds a turn, since a boot is repeated every two.
  void _insist(TurnId turn) {
    if (!amSeated || _left) return;
    final last = _insistedAt[turn];
    if (last != null && clock.nowMs - last < 5000) return;
    _insistedAt[turn] = clock.nowMs;
    final action = _races[turn]?.action;
    if (action != null && action.author == signer.publicKey) {
      transport.broadcast(action.toJson(), everywhere: true);
    } else {
      _emit(EventKind.heartbeat, {'hand': game.handNumber, 'step': step, 'reads': transport.paths}, everywhere: true);
    }
  }

  final Map<TurnId, int> _insistedAt = {};

  /// The rule for a boot: countersign when this peer agrees of its own
  /// knowledge — the seat's clock has run out by this peer's reckoning,
  /// or it has been silent past [silenceAfterMs] — and it holds no
  /// play for the turn; holding the play, rebroadcast that instead,
  /// since the boot may only have been a dropped message.
  void _considerCountersigning(TurnId turn, TableEvent boot) {
    if (!amSeated) return;
    final race = _races[turn]!;
    if (_turnSeat[turn] == mySeat) return _insist(turn);
    if (race.action != null) {
      // The booter did not hear it; say it where they can.
      transport.broadcast(race.action!.toJson(), everywhere: true);
      return;
    }
    if (_myWitness.containsKey(turn) || !connectedToMajority || writesRefused) return;
    final seat = _turnSeat[turn]!;
    final holder = holders[seat];
    if (holder is HumanSeat && !_mayBackBoot(holder.key)) return;
    // By this peer's own accounting of the seat's clock; the tick asks
    // again every second until it agrees. For a held seat, the juror's
    // clock and silence ([_jurorOut]).
    final agrees = holder is HumanSeat ? _overdue(turn, seat) || _silent(holder.key) : _jurorOut(seat);
    if (!agrees) return;
    _witness(turn, boot);
  }

  void _witness(TurnId turn, TableEvent of) {
    _myWitness[turn] = of.id;
    final holder = holders[of.seat];
    if ((of.kind == EventKind.boot || of.kind == EventKind.absent) && holder is HumanSeat) _bootBacked[holder.key] = turn;
    final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
      'event': of.id,
      'hand': turn.hand,
      'turn': turn.index,
      'seat': of.seat,
    });
    transport.broadcast(w.toJson());
    _myWitnessEvents[turn] = w;
    _accept(w);
  }

  void _onWitness(TableEvent event) {
    if (!_humans.contains(event.author)) return;
    _relayIfAppealed(event);
    final id = event.witnessed;
    final turn = event.turn;
    final proposal = _proposals[id];
    if (proposal != null) {
      if (proposal.settled) return;
      proposal.forAction.add(event.author);
      proposal.witnessEvents.add(event);
      return _settleJury(id);
    }
    if (event.body['leave'] == true) return _onLeaveWitness(event);
    if (event.body['jury'] == true) {
      // For a proposal not seen yet: kept by its id, never deferred,
      // since its position is the proposer's, not a turn of this hand.
      _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
      _earlyWitnessEvents.putIfAbsent(id, () => []).add(event);
      return;
    }
    final race = _races[turn];
    if (race != null) {
      if (race.settled) {
        if (_lateEscrowAt(turn)) {
          if (race.boots.any((b) => b.id == id)) {
            race.forRemoval.add(event.author);
            race.witnessEvents.add(event);
            _settleLateEscrow(turn);
          } else if (race.action?.id != id && !race.rivals.containsKey(id)) {
            // To a claim not heard here yet, perhaps: kept for it.
            _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
            _earlyWitnessEvents.putIfAbsent(id, () => []).add(event);
          }
        }
        // Backing for the game's end at a turn worked out here first
        // ([_lateEndingAt]), or for a claim of it not heard yet.
        if (_lateEndingAt(turn)) {
          if (race.ends.any((c) => c.id == id)) {
            race.forEnd.add(event.author);
            race.witnessEvents.add(event);
            _settleLateEnding(turn);
            return;
          }
          if (race.action?.id != id && !race.boots.any((b) => b.id == id) && !race.rivals.containsKey(id)) {
            _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
            _earlyWitnessEvents.putIfAbsent(id, () => []).add(event);
          }
        }
        return _catchUp(turn);
      }
      if (race.ends.any((c) => c.id == id)) {
        race.forEnd.add(event.author);
        race.witnessEvents.add(event);
        return _settle(turn);
      }
      if (race.action?.id == id) {
        race.forAction.add(event.author);
        race.witnessEvents.add(event);
        return _settle(turn);
      }
      if (race.boots.any((b) => b.id == id)) {
        race.forRemoval.add(event.author);
        race.witnessEvents.add(event);
        return _settle(turn);
      }
      if (race.rivals.containsKey(id)) {
        race.forRival[id]!.add(event.author);
        race.witnessEvents.add(event);
        return _settle(turn);
      }
    }
    if (_compare(turn) > 0) return _defer(event);
    _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
    _earlyWitnessEvents.putIfAbsent(id, () => []).add(event);
  }

  void _settle(TurnId turn) {
    final race = _races[turn]!;
    if (race.settled) return;
    final of = _participantsAt(turn);
    final needed = _majority(of);
    final seat = _turnSeat[turn]!;
    // A bot seat's other move, backed by a majority: that is the one
    // that carried, and this side ends on it too.
    for (final e in race.forRival.entries.toList()) {
      if (e.value.intersection(of).length >= needed && race.forAction.intersection(of).length < needed) {
        _trace('at $turn bot seat $seat\'s other move carried; taken instead of the one heard first');
        race.adopt(e.key);
        break;
      }
    }
    final forAction = race.forAction.intersection(of);
    final forRemoval = race.forRemoval.intersection(of);
    final forEnd = race.forEnd.intersection(of);
    // A turn a claim of the game's end could still carry is not split:
    // the people are ending it, and there is no jury to put it to.
    final ending = race.ends.isNotEmpty && _endingCanCarry(turn);
    if (forAction.length >= needed) {
      _carryAction(turn, race, race.action!, of);
    } else if (forRemoval.length >= needed) {
      if (holders[seat] is HumanSeat) {
        _carryRemoval(turn, race, race.boots.first, of);
      } else {
        _carryEscrow(turn, race, race.boots.first, of);
      }
    } else if (forEnd.length >= needed) {
      _carryEnded(turn, race, race.ends.first, of);
    } else if (race.split) {
      _pause = Pause.waitingForJury; // still, whatever else was reconsidered
    } else if (race.action != null || race.forRemoval.isNotEmpty) {
      // Something proposed, and not carried. Deadlocked once neither
      // side can still reach a majority: the action needs everyone who
      // has not backed the boot, the boot everyone but the seat itself
      // who has not witnessed the action — and no vote is coming from
      // anyone this peer has not heard from for two minutes, who
      // cannot be removed before their own turn. Only the jury breaks a
      // deadlock.
      final holder = holders[seat];
      if (holder is! HumanSeat && race.boots.isNotEmpty) {
        // A held seat's juror's move against the escrow, and neither
        // can carry: as at a person's seat, save that the juror is no
        // voter to leave out of the escrow's count.
        final gone = of.where((k) => k != signer.publicKey && _silent(k)).toSet();
        final moveReachable = of.difference(forRemoval).difference(forEnd).difference(gone.difference(forAction)).length >= needed;
        final escrowReachable = of.difference(forAction).difference(forEnd).difference(gone.difference(forRemoval)).length >= needed;
        if (!moveReachable && !escrowReachable && !ending) {
          race.split = true;
          _pause = Pause.waitingForJury;
          _trace('split at $turn: ${forAction.length} for bot seat $seat\'s juror, ${forRemoval.length} for the escrow');
        }
        return;
      }
      if (holder is! HumanSeat) {
        // Two moves for a bot seat, and neither can carry: everyone who
        // could still vote is behind one or the other or silent. The
        // same card, as it happens, but two events, and a record holds
        // one. Only the jury breaks it ([_judge]).
        if (race.rivals.isEmpty || !_rivalsDeadlocked(race, of)) return;
        race.split = true;
        _pause = Pause.waitingForJury;
        _trace('split at $turn: bot seat $seat said two ways, neither with a majority behind it');
        return;
      }
      final gone = of.where((k) => k != signer.publicKey && _silent(k)).toSet();
      // Nor is the boot anyone's to back who has backed this person's
      // leave: each backs one way out of a seat ([_mayBackBoot]). At a
      // table of four, two for the leave and two for the boot would be
      // a turn neither could carry.
      final leaving = _leaveBackers[holder.key] ?? const <PublicKey>{};
      final actionReachable = of.difference(forRemoval).difference(forEnd).difference(gone.difference(forAction)).length >= needed;
      final removalReachable = of
              .difference(forAction)
              .difference(forEnd)
              .difference({holder.key})
              .difference(leaving.difference(forRemoval))
              .difference(gone.difference(forRemoval))
              .length >=
          needed;
      if (!actionReachable && !removalReachable && !ending) {
        race.split = true;
        _pause = Pause.waitingForJury;
        _trace('split at $turn: ${forAction.length} for the action, ${forRemoval.length} against');
      }
    }
  }

  /// Whether no move for a bot seat can still carry: every
  /// participant who could vote is behind one of them already or has
  /// gone silent, and none of the moves has a majority among them.
  bool _rivalsDeadlocked(_Race race, Set<PublicKey> of) {
    final needed = _majority(of);
    final backing = [race.forAction.intersection(of), for (final w in race.forRival.values) w.intersection(of)];
    final committed = {for (final w in backing) ...w, ...race.forEnd};
    // As at a person's seat: nobody this side has not heard from for
    // two minutes is a vote still coming, and this side always is.
    final free = of.difference(committed).where((k) => k == signer.publicKey || !_silent(k)).length;
    return backing.every((w) => w.length + free < needed);
  }

  /// The seat's action wins the race for [turn]: by a majority, or by
  /// a juror's [verdict] where no majority could be had.
  void _carryAction(TurnId turn, _Race race, TableEvent e, Set<PublicKey> of, {TableEvent? verdict}) {
    race.settled = true;
    final seat = _turnSeat[turn]!;
    _spend(turn, seat);
    final d = _deal;
    if (e.kind == EventKind.deal) {
      // Whose keys carried for this seat. One keys message settles a
      // seat's first round, so this is the same on every side and for
      // the verifier — which is what makes it a better answer to who
      // holds a bot seat than a draw each peer reads for itself
      // ([botHolders]).
      if (e.round == 0) _keyedBy.putIfAbsent(turn.hand, () => {})[seat] = e.author;
      _applyDeal(e, seat);
    } else if (e.kind == EventKind.pass) {
      if (d != null) {
        _applyPass(d, seat, e);
      } else {
        game.setPass(seat, [for (final c in e.body['cards'] as List) Card.parse(c as String)]);
      }
    } else {
      final card = Card.parse(e.body['card'] as String);
      if (d != null && d.acceptPlay(seat, Map<String, Object?>.from(e.body), verified: true) != card.index) {
        _trace('a play settled that the deal does not open: $e');
      }
      game.play(seat, card);
      played.add(card);
    }
    _log(Decision(
      turn: turn,
      event: e,
      witnesses: {...race.forAction, if (verdict != null) verdict.author},
      among: of,
      verdict: verdict,
    ));
    _trace('settled $turn ${e.kind.name} by ${race.forAction.intersection(of).length}${verdict != null ? ' and the jury' : ''}');
    if (e.kind == EventKind.play && e.author == _personOf(seat)) _takeGrowth(turn.hand, e);
    _liftPause();
    _closeTurn(turn);
    if (turn.isDeal && turn.dealRound == 0) _checkSealed(turn.hand);
  }

  /// The removal wins the race for [turn]: by a majority, or by a
  /// juror's [verdict].
  void _carryRemoval(TurnId turn, _Race race, TableEvent claim, Set<PublicKey> of, {TableEvent? verdict}) {
    race.settled = true;
    _removedAtTurn.add(turn);
    final seat = _turnSeat[turn]!;
    _log(Decision(
      turn: turn,
      event: claim,
      witnesses: {...race.forRemoval, if (verdict != null) verdict.author},
      removal: true,
      among: of,
      verdict: verdict,
    ));
    _trace('booted seat $seat at $turn by ${race.forRemoval.intersection(of).length}${verdict != null ? ' and the jury' : ''}');
    _remove(seat, at: turn, how: claim.kind);
    _liftPause();
    _botTurn(turn, seat);
    _reconsider();
    if (turn.isDeal && turn.dealRound == 0) _checkSealed(turn.hand);
  }

  /// The escrow wins the race for [turn]: by a majority, or by a
  /// juror's [verdict]. The held seat is the escrow's from this turn to
  /// the end of the hand, at every side alike, because the record says
  /// so. Every custodian gives its piece; the move the turn still owes
  /// is said by the first of them still heard and settled like any
  /// move, so the turn opens again, for the escrow. In the deal nobody
  /// can take the seat's steps, and the hand is given up; at the audit
  /// the pieces close it.
  void _carryEscrow(TurnId turn, _Race race, TableEvent claim, Set<PublicKey> of, {TableEvent? verdict}) {
    final seat = _turnSeat[turn]!;
    final hand = turn.hand;
    final holder = botHolders(hand)[seat];
    _log(Decision(
      turn: turn,
      event: claim,
      witnesses: {...race.forRemoval, if (verdict != null) verdict.author},
      removal: true,
      among: of,
      verdict: verdict,
    ));
    _trace('bot seat $seat to the escrow at $turn by ${race.forRemoval.intersection(of).length}${verdict != null ? ' and the jury' : ''}');
    _escrowed.putIfAbsent(hand, () => {})[seat] = turn;
    // One that was heard and did not play is left out of the next
    // draw; one that went quiet the draw leaves out anyway.
    if (holder != null && _liveJurors(hand).contains(holder)) _letGo.add(holder);
    // The turn is the escrow's now, and the claims against the seat's
    // juror are done with. Not the moves said for the seat: a move by
    // a juror of the hand is good after the escrow too, whoever said
    // it ([_mayAct]) — the seat's own juror's, said before it knew, as
    // much as a custodian's. A side that let one go here would never
    // take it up again, since every copy after the first is read as
    // already seen, and would sit at this turn while the table carried
    // it. So the moves stay, with whoever backed them, and only a side
    // whose voice went to the escrow has one again. The evidence stays
    // too, for a side carried here later.
    //
    // Not at the audit, where there is no move for the escrow to make:
    // a seat given to the escrow is audited from its pieces, in the
    // open, with nothing said ([_isEscrowedAudit]).
    final claims = {for (final b in race.boots) b.id};
    race
      ..boots.clear()
      ..forRemoval.clear()
      ..split = false;
    if (turn.isAudit) {
      race
        ..action = null
        ..forAction.clear()
        ..rivals.clear()
        ..forRival.clear();
    }
    if (turn.isAudit || claims.contains(_myWitness[turn])) {
      _myWitness.remove(turn);
      _myWitnessEvents.remove(turn);
    }
    _liftPause();
    final d = _deal;
    if (d != null) {
      d.seatLeft(seat);
      _releaseFor(seat);
    }
    // A seat given up with a step of the deal still to take is a deal
    // that cannot finish: its juror drew the key, and no juror says a
    // held seat's deal steps for it. Its last step is the declaration;
    // once that has settled, nothing of the deal is owed by it and the
    // escrow plays it from there.
    if (game.phase == Phase.dealing && _races[TurnId.deal(hand, TurnId.dealRounds - 1, seat)]?.settled != true) {
      return _giveUpUndealtHand(seat);
    }
    // This side's voice, back from the escrow, goes to the move it
    // heard first, as it would have on hearing it now.
    final kept = race.action;
    if (kept != null && amSeated && kept.author != signer.publicKey && !_myWitness.containsKey(turn)) _witness(turn, kept);
    _settle(turn);
    // Pieces and moves that came before this side saw the escrow were
    // put by: taken up now.
    _drainFuture();
    _takeUpSeat(seat);
    _notify();
  }

  // ---- the deal -------------------------------------------------------------
  //
  // The cards of a sealed table come from a deal every seat shuffles
  // with a proof, and each person's cards are theirs alone to see
  // (docs/03-fair-deal.md). Here the deal is turns like any other. At the hand's start
  // the four keys turns open at once; when they are settled the
  // shuffle turns open one at a time in seat order; when the deck is
  // done the tokens turns open at once, then the declarations; then
  // the engine is dealt what this side can see and the hand goes on as
  // at any table. A bot's turn is public work the session already did.
  // A person's turn settles by their action, which the session
  // verified on arrival, or by their removal, after which the seat is
  // a bot whose secret is awaited from escrow: its turns stall until
  // the pieces come, released by every seat and juror that holds one,
  // said again every few seconds until the secret is known.

  /// This hand's deal, at a sealed table.
  DealSession? _deal;

  /// The releases heard, by hand, to hand on to a peer behind — and
  /// to the verifier, which rebuilds a departed seat's secret from
  /// them when no audit vouched for it.
  final Map<int, List<TableEvent>> _releases = {};

  /// Every release of an escrow piece heard at this table, in the
  /// order heard: evidence beside the record, like [juries].
  List<TableEvent> get releases => [for (final h in _releases.keys.toList()..sort()) ..._releases[h]!];

  /// Turns of a departed seat waiting on its secret, by turn.
  final Map<TurnId, int> _stalled = {};

  /// Every key ever proposed as a juror at this table: what a seat may
  /// escrow to.
  final Set<PublicKey> _everProposed = {};
  int _lastReleaseAt = _never;

  /// What this side knows of the current hand's deal; null at a
  /// seeded table.
  DealSession? get deal => _deal;

  /// The deal of any hand so far, for a view replaying the record
  /// behind the table.
  DealSession? dealOf(int hand) => _dealsByHand[hand];
  final Map<int, DealSession> _dealsByHand = {};

  /// The deal is built once, and a bot seat's holder is fixed in it,
  /// so a table that holds bots with the jury waits for the jury
  /// before building it. The jury is proposed as the hand opens and
  /// settles a moment later, and a table with bot seats waits past
  /// that for a jury big enough to hold them — the call for a juror
  /// of last resort is what answers on a quiet night
  /// (docs/04-live-play.md).
  ///
  /// It waits for as long as that takes. A bot's hand dealt in the
  /// open is the table's to see, and at two people and two bots that
  /// is the other person's hand by subtraction; a rated table played
  /// that way is one a person can win by reading. So there is no
  /// point past which it goes ahead without: a table nobody can hold
  /// waits, and says so.
  void _startDealWhenReady() {
    // A deal for *this* hand: _deal still holds the last one until the
    // new one replaces it, and testing it for null strands every hand
    // after the first.
    if (!spec.sealed || done) return;
    if (_deal != null && _deal!.hand == game.handNumber) return;
    if (_hasBotSeats) {
      // A jury that holds every bot seat — which covers waiting for a
      // jury at all, since a hand with no jury holds nothing.
      final held = botHolders(game.handNumber);
      if (!_everyBotHeld(held)) {
        if (!_shortOfJurors) {
          _shortOfJurors = true;
          _trace('hand ${game.handNumber}: waiting for a jury that can hold the bot seats');
          _notify();
        }
        return;
      }
      if (_shortOfJurors) {
        _shortOfJurors = false;
        _notify();
      }
    }
    _startDeal();
  }

  bool _everyBotHeld(Map<int, PublicKey> held) {
    for (final s in _botSeatsAt(game.handNumber)) {
      if (!held.containsKey(s)) return false;
    }
    return true;
  }

  bool get _hasBotSeats => holders.any((h) => h is BotSeat);

  void _startDeal({bool drain = true}) {
    final c = _prepared ?? crypto!;
    final held = botHolders(game.handNumber);
    _heldByHand[game.handNumber] = held;
    final from = _sealedTo.containsKey(game.handNumber) ? _sealedTo[game.handNumber] : _provisionalDraw(game.handNumber).id;
    if (from != null) _heldFrom[game.handNumber] = from;
    // The deal's notion of this side's seat is not the table's: a juror
    // sits at no seat here and still acts for the bot seat it holds.
    final me = amSeated
        ? mySeat
        : _beforeSummons(game.handNumber)
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
          switch (holders[s]) {
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
      // with the secret this side's keys were made from ([_refixHolders]).
      // A new one would put this side's own key apart from the one on the
      // record — a session keeps its own seat's keys and no other — and
      // nothing shuffled from the record's could be checked here
      // (sealed_to_draw_test.dart). A client built again after a reload
      // has the secret its keys for the hand were made from in its
      // journal, kept for this.
      mySecret: before != null && before.mySeat == me ? before.mySecret : (me != null && me == mySeat ? journal?.secretFor(game.handNumber) : null),
      myKey: signer.publicKey,
      wrap: signer.sharedSecretWith,
      random: _random,
    );
    _dealsByHand[game.handNumber] = _deal!;
    final kept = _deal!.mySecret;
    if (amSeated && me == mySeat && kept != null) journal?.keep(game.handNumber, kept);
    // Which juror holds which bot seat, said once as the deal is
    // built. It is no secret — the assignment is the hand's first
    // jury read in its drawn order, so every side works out the same
    // one — and it is the fact every other line about a bot seat
    // refers to: the seat going to the escrow, the pieces coming in,
    // the seat played on by somebody else.
    if (held.isNotEmpty) {
      _trace('hand ${game.handNumber}: the jury holds bot '
          '${held.entries.map((e) => 'seat ${e.key} (${e.value.substring(0, 8)})').join(', ')}');
    }
    _stalled.clear();
    for (var s = 0; s < seatCount; s++) {
      _openTurn(TurnId.deal(game.handNumber, 0, s), s);
    }
    // And whatever came for those turns before there was a deal to
    // put it in. A hand's first four steps go out the moment the
    // table has a jury, and a juror summoned a moment later — or any
    // peer whose own deal waited on a draw it had not heard — has
    // them in hand before it has built the session that checks them:
    // kept, because a turn that is not open yet is not a turn the
    // event is wrong for ([_defer]). They are drained here: the other
    // drains run when a turn settles, when a jury changes and when the
    // assignment is fixed again, and the steps this side needs to
    // settle its first turn are exactly these.
    //
    // Not yet when the deal is built again ([_refixHolders]): the
    // steps that already settled go back in first.
    if (!drain) return;
    // A hand with nobody at the table to key it is sealed to no draw at
    // once ([_checkSealed]); any other waits for its first person's keys.
    _checkSealed(game.handNumber);
    _drainFuture();
    _bootLiars();
    _actOnDeal();
  }

  /// Whether [who] may act for [seat]: the person sitting there, or
  /// the juror holding it when it is a bot seat the jury holds. A bot
  /// seat nobody holds is acted for by nobody — every peer works its
  /// move out and no event is made.
  bool _mayAct(int seat, PublicKey who, int hand) {
    final holder = holders[seat];
    if (holder is HumanSeat) return holder.key == who;
    final held = botHolders(hand)[seat];
    if (held == null || !_jurorsOf(hand).contains(who)) return false;
    // Before the seat's keys are said, any juror of the hand: who the
    // draw named can read differently here for a moment while a redraw
    // is in flight ([_asKeyed]), and the keys settle it. From then on
    // only the juror that made them, until the record gives the seat
    // to the escrow ([_carryEscrow]) — a move by anybody else before
    // that is a move by the escrow this side has not seen yet — and
    // from then on any juror that has the key: whoever came by it, and
    // the seat's own juror if it is back.
    if (_keyedBy[hand]?[seat] == null) return true;
    return _isEscrowed(hand, seat) || who == held;
  }

  /// Who this table has to reach directly: the people at it, and —
  /// from a seat — the jurors of the hand in play. A transport that
  /// dials its peers — the app's mesh — opens a channel to each; a
  /// relay transport ignores it. Said again whenever a jury carries or
  /// a hand opens, since a redrawn jury is a different set of
  /// strangers.
  ///
  /// A juror does not dial its fellow jurors. What a juror must hear
  /// is the table, and the seats dial it for that; a jury of six
  /// dialling itself as well would be fifteen more connections for
  /// the appeals and verdicts that pass between jurors, which are a
  /// handful of small events a hand and can take the relay.
  void _reachOut() => transport.reach({
        ...participants,
        if (amSeated) ..._jurorsOf(game.handNumber),
      });

  /// Each hand's bot-seat holders, fixed once the hand's deal is built:
  /// a bot seat's holder is in that deal, and a jury redrawn mid-hand
  /// would otherwise move the seat out from under it — the juror still
  /// saying its steps while everyone, itself included, stopped
  /// accepting them for it.
  final Map<int, Map<int, PublicKey>> _heldByHand = {};

  /// And which jury each fixed assignment was read from, so that one
  /// fixed before the hand's first jury had arrived can be told from
  /// one fixed after ([_refixHolders]).
  final Map<int, String> _heldFrom = {};

  /// The draw each hand's deal is sealed to, as the record says it: the
  /// one named by the keys of the first person at the table whose keys
  /// for the hand have settled ([_checkSealed]). Null for keys that
  /// name none, the hand's bot seats dealt in the open. Absent until
  /// the record has said.
  final Map<int, String?> _sealedTo = {};


  /// Who keyed each seat at [hand], by the event that settled its
  /// first deal round.
  final Map<int, Map<int, PublicKey>> _keyedBy = {};

  /// Who this side has settled the keys of, at [hand]: the seats whose
  /// holder the record has already named here. For a test, and for a
  /// view that wants to know how far the deal has been read.
  Map<int, PublicKey> keyedBy(int hand) => _keyedBy[hand] ?? const {};

  /// Which juror holds which bot seat at [hand]. Empty when the table
  /// is unsealed, or when there is no jury to hold them — in which
  /// case a bot seat stays public work, which is what a table with
  /// nobody online to draw from falls back to.
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
    return _asKeyed(hand, assignBots(_provisionalDraw(hand).jurors, _botSeatsAt(hand)));
  }

  /// The holders the draw the record seals [hand] to names.
  Map<int, PublicKey> _heldAtSeal(int hand) {
    final jury = _juryById(_sealedTo[hand], hand);
    return jury == null ? {} : assignBots(jury, _botSeatsAt(hand));
  }

  /// A draw carried here for [hand], by its event's id.
  List<PublicKey>? _juryById(String? id, int hand) {
    if (id == null) return null;
    for (final d in juries) {
      if (d.event.id == id && d.event.hand == hand) return d.event.jurors;
    }
    return null;
  }

  /// Whether [jury] can hold every one of [bots]: a draw of fewer than
  /// [juryToHoldBots] holds none.
  bool _holdsAll(List<PublicKey> jury, List<int> bots) => assignBots(jury, bots).length == bots.length;

  /// The draw a hand's bot seats are read from here until the record
  /// says which one its deal is sealed to ([_sealedTo]).
  ///
  /// The first drawn for the hand that can hold every bot seat, in the
  /// order every side reads them ([_juriesDrawnFor]) rather than the
  /// order they settled here — _jurorsOf is a set whose iteration order
  /// follows this peer's own history, and two peers that saw the same
  /// juries in a different order would hand the same seat to different
  /// jurors. Not a draw that holds nothing: a small redraw proposed from
  /// an earlier place, read first, would put a hand's bot seats in the
  /// open at one side while the others dealt them to a jury.
  ///
  /// Or the hand's first jury as the summons gave it, where the event
  /// that drew it has not been carried here yet ([_firstSummons]). Only
  /// that one: a juror topped up mid-hand is summoned with the jury as
  /// it stands then, and that list names a different holder for each
  /// seat.
  ({String? id, List<PublicKey> jurors}) _provisionalDraw(int hand) {
    final bots = _botSeatsAt(hand);
    final drawn = _juriesDrawnFor(hand);
    for (final d in drawn) {
      if (_holdsAll(d.event.jurors, bots)) return (id: d.event.id, jurors: d.event.jurors);
    }
    if (drawn.isNotEmpty) return (id: drawn.first.event.id, jurors: drawn.first.event.jurors);
    final summoned = _firstSummons[hand];
    return (id: summoned?.juryId, jurors: summoned?.jurors ?? const <PublicKey>[]);
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
  /// names for the seat ([_keysNameTheDraw]); its juror waits for it
  /// before making them ([_actOnDeal]).
  void _checkSealed(int hand) {
    if (!spec.sealed || _sealedTo.containsKey(hand)) return;
    final bots = _botSeatsAt(hand);
    String? named;
    int? by;
    for (var s = 0; s < seatCount; s++) {
      if (bots.contains(s)) continue;
      final turn = TurnId.deal(hand, 0, s);
      final race = _races[turn];
      if (race == null || !race.settled) return;
      final e = race.action;
      if (_removedAtTurn.contains(turn) || e == null) continue;
      final jury = e.body['jury'];
      // A draw not carried here yet: [_settleJury] looks again.
      if (jury is String && _juryById(jury, hand) == null) return;
      named = jury is String ? jury : null;
      by = s;
      break;
    }
    // With no person left to say it — every seat a bot's when the hand
    // began, a leaver's client looking on — there is no jury to seal to.
    _sealedTo[hand] = named;
    _trace('hand $hand: sealed to ${named != null ? 'the draw ${named.substring(0, 8)}' : 'no draw, its bot seats in the open'}'
        '${by != null ? ', by seat $by\'s keys' : ', with nobody at the table to key it'}');
    _refixHolders(hand);
    // A bot seat's keys waited for this ([_botActs]).
    for (final s in bots) {
      _takeUpSeat(s);
    }
    _drainFuture();
    _actOnDeal();
    _notify();
  }

  /// Whether a seat's keys name a draw this side can take them against:
  /// a person's, none or a draw carried here that holds every bot seat;
  /// a held seat's, the draw the record has sealed the hand to, made by
  /// the juror that draw names for the seat ([_checkSealed]).
  bool _keysNameTheDraw(TableEvent e, int seat) {
    final hand = e.turn.hand;
    final named = e.body['jury'];
    if (named != null && named is! String) return false;
    final bots = _botSeatsAt(hand);
    if (!bots.contains(seat)) {
      if (named == null) return true;
      final jury = _juryById(named as String, hand);
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
  /// to play ([_botActsHere], `_deal.gone`). It becomes a bot seat
  /// the jury holds at the hand after, when it is dealt cards nobody
  /// has seen.
  List<int> _botSeatsAt(int hand) {
    final out = <int>[];
    for (var s = 0; s < seatCount; s++) {
      if (holders[s] is! BotSeat) continue;
      final was = spec.seats[s];
      if (was is HumanSeat) {
        // Where the leaver stood, not where this peer noticed: a
        // removal is placed at a turn, and every side reads the same
        // hand from it.
        final at = _removedAt[was.key];
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

  /// The juries drawn for [hand] itself, earliest first — where the
  /// record puts them, not where this peer happened to hear them.
  ///
  /// The first of them is what a bot seat's holder is read from: not
  /// the union of every jury in force at the hand. A redraw mid-hand
  /// moves the jury for escrow and appeals, and must not move a seat
  /// out from under the deal it is already in; and the verifier, which
  /// sees every jury at once, has to land on the same one this did.
  ///
  /// The hand's own juries and no others: _juriesFor falls back to the
  /// last hand that had one, which is right for escrow and appeals and
  /// wrong here — the deal would be built against the jury of the hand
  /// before, and the verifier, reading this hand's own, would name a
  /// different juror for the seat.
  ///
  /// Ordered by the record rather than by when it was heard: a juror
  /// summoned into a redraw hears the redraw that summoned it before it
  /// is carried the draw that came first, and taking the later one for
  /// the first would name a different juror for every bot seat.
  List<Decision> _juriesDrawnFor(int hand) => _juriesFor(hand).where((d) => d.event.hand == hand).toList()..sort(compareJuries);

  /// The assignment against what the record now says it should be.
  /// Both of its two inputs can arrive after it was fixed:
  ///
  /// - **The hand's first jury.** A juror carried the record hears the
  ///   redraw that summoned it before the draw that came first, and
  ///   any peer can hear two juries out of order.
  /// - **Which seats are bots.** A person leaving turns their seat
  ///   into one, and a peer that has not heard the leave counts a seat
  ///   fewer ([_botSeatsAt]). The leave decides a hand the assignment
  ///   is read for, so one arriving late moves it.
  ///
  /// Fixed again, and the deal built again with it — and the steps
  /// that already settled fed into the new session from the races
  /// that settled them, so that rebuilding costs nothing already
  /// agreed.
  void _refixHolders(int hand) {
    final standing = _heldByHand[hand];
    if (standing == null) return;
    final from = _heldFrom[hand];
    final sealed = _sealedTo.containsKey(hand);
    // Short of the record's word, a deal dealt with its bots in the
    // open stays that way: it went ahead for want of a jury, and one
    // arriving later does not reach back into it.
    if (!sealed && from == null) return;
    final draw = sealed
        ? (id: _sealedTo[hand], jurors: _juryById(_sealedTo[hand], hand) ?? const <PublicKey>[])
        : _provisionalDraw(hand);
    if (!sealed && draw.jurors.isEmpty) return;
    // The draw against the one standing here. They agree almost always
    // — a juror fixes from its summons a second before the draw it was
    // summoned into is carried to it — and agreeing is not worth a
    // rebuild: the assignment is the same, so say the jury it came from
    // and leave the deal alone.
    final again = assignBots(draw.jurors, _botSeatsAt(hand));
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
    _trace('hand $hand: ${sealed ? 'the record seals it to another draw than' : now == from ? 'a seat turned into a bot after' : 'its first jury came after'} '
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
        final race = _races[TurnId.deal(hand, r, seat)];
        final e = race?.action;
        if (race != null && race.settled && e != null) _applyDeal(e, seat);
      }
    }
    // With them back in, the deal may be further on than the turns
    // open here: a round whose steps had all settled opens the next.
    // And only then what was held back for it, taken against the whole
    // of the deal rather than the part rebuilt so far: the other way
    // round, a round could close with the deal still at its keys and
    // nothing to ask the deal to go on again.
    _advanceDeal();
    // Anything refused against the old assignment is worth another
    // look now: it was kept rather than dropped for exactly this.
    _drainFuture();
    _actOnDeal();
  }

  /// The bot seat this side holds at that assignment, if any.
  int? _seatHeldHere(Map<int, PublicKey> held) {
    for (final e in held.entries) {
      if (e.value == signer.publicKey) return e.key;
    }
    return null;
  }

  bool _roundDone(int round) =>
      Iterable<int>.generate(seatCount).every((s) => _races[TurnId.deal(game.handNumber, round, s)]?.settled == true);

  /// The deal round whose turns are open: the first not yet settled.
  int get _currentDealRound {
    for (var r = 0; r < TurnId.dealRounds; r++) {
      if (!_roundDone(r)) return r;
    }
    return TurnId.dealRounds - 1;
  }

  /// Opens what the deal's progress allows, and deals the engine when
  /// it is done.
  void _advanceDeal() {
    final d = _deal;
    if (d == null || game.phase != Phase.dealing) return;
    final h = game.handNumber;
    if (!_roundDone(0)) return;
    // Shuffles, one at a time, in seat order: a bot's or a departed
    // seat's is computed by all when it is next, a person's awaited.
    for (var s = 0; s < seatCount; s++) {
      final t = TurnId.deal(h, 1, s);
      if (_races[t]?.settled == true) continue;
      if (!_races.containsKey(t) && (d.hasShuffled(s) || holders[s] is BotSeat || d.nextShuffler == s)) _openTurn(t, s);
      if (_races[t]?.settled != true) return;
    }
    if (d.deck == null) return;
    for (var s = 0; s < seatCount; s++) {
      _openTurn(TurnId.deal(h, 2, s), s);
    }
    if (!_roundDone(2)) return;
    for (var s = 0; s < seatCount; s++) {
      _openTurn(TurnId.deal(h, 3, s), s);
    }
    if (!_roundDone(3)) return;
    _dealt(d);
  }

  /// The deal is done: the engine gets what this side can see, and
  /// the hand begins — unless nobody declared the lead card.
  void _dealt(DealSession d) {
    if (game.phase != Phase.dealing) return;
    final leader = lies == Lie.hide ? null : d.leader;
    if (leader == null) {
      if (_pause != Pause.waitingForLead) _trace('nobody declared the lead card');
      _pause = Pause.waitingForLead;
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
    if (_pause == Pause.waitingForLead) _pause = null;
    _trace('dealt hand ${game.handNumber}, seat $leader to lead');
    _openPlay();
  }

  /// A hand nobody can finish, opened where it stands and then given
  /// up. Two things leave one (docs/03-fair-deal.md), and neither can
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
  /// what [_herePosition] reads). When the audits are in, every card is
  /// open — which is also how a verifier can see for itself that the
  /// hand was past saving — and the hand is given up rather than played
  /// on, because a hand everyone can see is not a hand.
  void _openTheHand(String why) {
    if (_openingAudit || !spec.sealed || _deal == null) return;
    _openingAudit = true;
    _trace('hand ${game.handNumber}: $why; opening it');
    for (var s = 0; s < seatCount; s++) {
      _openTurn(TurnId.audit(game.handNumber, s), s);
    }
    _sayOpenReleases();
    _actOnDeal();
    _drainFuture();
  }

  /// Whether this hand is being opened rather than played
  /// ([_openTheHand]).
  bool _openingAudit = false;

  /// The deal is open and the hand is given up: nothing was passed and
  /// nothing was played, so nothing is scored, and the next hand is
  /// dealt in its place (docs/03-fair-deal.md), under a hand number of
  /// its own because that is where its turns live.
  ///
  /// Whoever was dealt the lead card and disclaimed it is marked here
  /// and removed at the first turn of theirs that opens ([_bootLiars]).
  /// It cannot be removed at the turn it lied at: that one settled
  /// long before the cards said so.
  void _giveUpHand() {
    final d = _deal;
    // Whoever the open hand shows to have broken it: the seat dealt the
    // lead card that said it held it nowhere, and the seat whose seal
    // would not open.
    final blamed = <int>{if (d?.lied case final seat?) seat};
    for (final seat in blamed) {
      final holder = holders[seat];
      if (holder is HumanSeat) _liars.add(holder.key);
    }
    _trace('hand ${game.handNumber} given up, opened${blamed.isEmpty ? '' : '; seat(s) $blamed broke it'}');
    _handEnds[game.handNumber] = HandState.givenUp;
    _openingAudit = false;
    _abandonHand();
  }

  /// The hand is over as an unplayed one: nothing is scored and the
  /// next is dealt in its place, under a hand number of its own
  /// because that is where its turns live.
  void _abandonHand() {
    _pause = null;
    // The turn the hand stopped at will never settle, and nothing is
    // owed at it: the hand it belongs to is over as an unplayed one.
    for (final t in List.of(_races.keys)) {
      if (t.hand == game.handNumber && _races[t]!.settled != true) _races.remove(t);
    }
    _stalled.removeWhere((t, _) => t.hand == game.handNumber);
    game.abandonHand();
    _openHand();
  }

  /// A hand whose deal cannot be finished, because a bot seat's juror
  /// has gone with a deal turn of that seat still open. Nobody can
  /// make that seat's keys or its shuffle: the holder drew the key, and
  /// where the keys never went out there is not even an escrow holding
  /// pieces of it. The hand is given up unscored and the next dealt in
  /// its place, to a jury drawn again without the one that went
  /// (docs/04-live-play.md).
  ///
  /// Without an audit, unlike the hand that is opened and given up. A
  /// hand stopped in its deal has nothing to show — nothing was passed
  /// and nothing was played — and the seat that stopped it cannot be
  /// opened to say so. The verifier takes an abandoned hand as a
  /// terminal state rather than an incomplete one.
  ///
  /// Follows from the record, and only from it: the escrow of a held
  /// seat that still owed a step of the deal ([_carryEscrow]), which a
  /// side behind is carried to like any removal ([_carryForward]).
  void _giveUpUndealtHand(int seat) {
    _trace('hand ${game.handNumber}: seat $seat cannot finish its deal; the hand is given up undealt');
    _handEnds[game.handNumber] = HandState.abandoned;
    _abandonHand();
  }

  /// The keys of seats this peer has proof against: each said it held
  /// the lead card nowhere and was dealt it.
  final Set<PublicKey> _liars = {};

  /// Boots whoever this peer has proof against, at whichever turn of
  /// theirs is open. A lie about the lead card is not a judgement call
  /// and not a clock running out — the record shows it, and every peer
  /// reads the same record — so there is nothing to wait for. Said
  /// again each tick until the seat is gone, since the turn it was
  /// said at may settle first.
  void _bootLiars() {
    if (_liars.isEmpty || !amSeated || _left || done) return;
    if (!connectedToMajority || writesRefused) return;
    for (var seat = 0; seat < seatCount; seat++) {
      final holder = holders[seat];
      if (holder is! HumanSeat || holder.key == signer.publicKey) continue;
      if (!_liars.contains(holder.key) || !_isParticipant(holder.key)) continue;
      if (!_mayBackBoot(holder.key)) continue;
      final turn = _openTurnOf(seat);
      if (turn == null || _myWitness.containsKey(turn)) continue;
      _emit(EventKind.boot, {'hand': turn.hand, 'turn': turn.index, 'seat': seat}, everywhere: true);
    }
  }

  /// Tells the engine who leads, from where the lead card sits now.
  void _declareLead() {
    final leader = _deal?.leader;
    if (leader != null && (game.phase == Phase.passing || game.phase == Phase.dealing)) game.declareLeader(leader);
  }

  /// This seat's own steps, whenever one is due: keys once a jury is
  /// in force to escrow to (or there is none to wait for, or ten
  /// seconds have passed), the shuffle when next, the tokens when the
  /// deck is done, the declaration when its hand is open, the audit
  /// when the hand is over.
  void _actOnDeal() {
    final d = _deal;
    if (d == null || _left || done) return;
    // The seat this side acts for in the deal: its own if it is a
    // player, or the bot seat it holds if it is a juror. A player that
    // has been removed acts for nothing.
    final h = game.handNumber;
    final me = d.mySeat;
    if (me == null || (mySeat != null && !amSeated)) {
      // A juror serving the hand that cannot see who holds its bot
      // seats, said once a hand. Most jurors hold nothing and that is
      // ordinary; a juror that can see no assignment at all is one
      // step from being the holder the table is waiting on, and from
      // the outside it looks exactly like a device that has stopped.
      if (mySeat == null && _serving.containsKey(h) && botHolders(h).isEmpty && holders.any((s) => s is BotSeat)) {
        _sayOnce(h, 'serving, but no bot seat is held as far as this side can see; '
            'juries drawn for it ${_juriesDrawnFor(h).length}, summoned into its first ${_firstSummons[h] != null}');
      }
      return;
    }
    TurnId? open(TurnId t) {
      final r = _races[t];
      return r != null && !r.settled && r.action == null ? t : null;
    }

    final keys = open(TurnId.deal(h, 0, me));
    if (keys != null) {
      final jurors = _jurorsOf(h);
      final waited = clock.nowMs - _openedAt[keys]!;
      if (jurors.isNotEmpty || presence == null || needsJuror || waited >= 10000) {
        // A juror holds a seat by the draw the record seals the hand
        // to, and makes no keys until the record has said which that is
        // ([_checkSealed]): read for itself, the draw is wrong for any
        // juror that heard a redraw before the draw that came first,
        // and keys made for the wrong seat are a step that settles —
        // the first action at a turn stands.
        if (!amSeated && !_sealedTo.containsKey(h)) return;
        // A held seat's shares are indexed by their custodian's place in
        // the list its keys name, which the record then grows
        // ([_applyGrowth]): every juror of the hand heard of here, in
        // the juries' own order. A person's escrow goes by sides, in no
        // order.
        d.custodians = amSeated ? (jurors.toList()..sort()) : _custodiansNow(h);
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
      if (m != null) _emitDeal(declare, 3, me, lies == null ? m : {'seat': m['seat'], 'position': -1});
    }
    final audit = open(TurnId.audit(h, me));
    if (audit != null && !_isEscrowedAudit(audit, me) && (game.phase == Phase.handOver || game.phase == Phase.gameOver || _openingAudit)) {
      _emitDeal(audit, 4, me, d.myAudit()!);
    }
  }

  /// How this client lies about the lead card, or null — which is every
  /// client but a simulated one. See [Lie].
  Lie? lies;

  /// A deal step for the seat it is taken for — this side's own, or
  /// the bot seat a juror holds, which is not the same as its seat at
  /// the table because a juror has none.
  void _emitDeal(TurnId turn, int round, int seat, Map<String, Object?> m) =>
      _emit(EventKind.deal, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'round': round, ...m});

  /// Whether [event] can be checked here now: for a deal step another
  /// seat sent, whether its checks have been made at the worker
  /// ([DealSession.workToTake]); if not, they are on their way, and
  /// the caller keeps the event for the drain that follows them back.
  /// This side's own steps are not checked ([_valid]).
  bool _checkable(TableEvent event) {
    final d = _deal;
    if (event.kind != EventKind.deal || d == null || _prepared == null || event.author == signer.publicKey) return true;
    return _workedOut(d.workToTake(event.round, Map<String, Object?>.from(event.body)));
  }

  /// What the deals here came to on their own and are waiting on
  /// ([DealSession.wanted]): the first deck, a departed seat's work.
  /// Sent at every change, since any change can be what set it off.
  void _sendWanted() {
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
    if (_cannotDeal != null || _closed) return;
    Zone.current.handleUncaughtError(DealWorkFailed(job, why), StackTrace.current);
    _cannotDeal = '$why';
    _trace('cannot deal: $why');
    clock.schedule(0, () {
      if (_closed) return;
      if (amSeated) {
        leave();
        _notify();
      } else {
        _notify();
        close();
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
    if (_lookAgainDue || _closed) return;
    _lookAgainDue = true;
    clock.schedule(0, () {
      _lookAgainDue = false;
      if (_closed) return;
      for (final d in List.of(_dealsByHand.values)) {
        d.resume();
      }
      _advanceDeal();
      _resumeStalled();
      _drainFuture();
      _actOnDeal();
      _notify();
    });
  }

  /// A settled deal step, applied. Verified on arrival; this side's
  /// own were made here.
  void _applyDeal(TableEvent e, int seat) {
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
    if (!ok) _trace('a deal step settled that the session would not take: $e');
    if (ok && e.round == 0) _applyGrowth(e.hand);
    if (e.round == 4 || d.gone.isNotEmpty) _resumeStalled();
  }

  /// A settled pass at a sealed table: the positions move, and the
  /// engine learns the cards this side can see.
  void _applyPass(DealSession d, int seat, TableEvent e) {
    final b = Map<String, Object?>.from(e.body);
    if (!d.acceptPass(b, verified: true)) _trace('a pass settled that the deal would not take: $e');
    final positions = [for (final p in b['positions'] as List) p as int];
    final cards = <Card>[];
    for (final p in positions) {
      final c = d.openedCardAt(p);
      if (c == null) break;
      cards.add(Card.deck[c]);
    }
    _declareLead();
    final to = (seat + game.passDirection.seatOffset) % seatCount;
    if (cards.length != positions.length && game.knowsHand(to)) {
      // Into a seat whose hand is seen here — a departed seat's, opened
      // from escrow — a pass has to open too, and this one has not yet.
      // A pass a seat could never open does not get this far: the
      // argument beside each seal is checked before the pass is taken
      // (docs/03-fair-deal.md). The engine waits rather than take a
      // hand it cannot fill.
      _trace('a pass into seat $to, whose hand is seen here, that will not open here yet: $e');
      return;
    }
    game.setPass(seat, cards.length == positions.length ? cards : null);
  }

  /// A departed seat's turn that cannot move until its secret is
  /// rebuilt: kept, and the table says why it waits.
  void _stall(TurnId turn, int seat) {
    _stalled[turn] = seat;
    _pause = Pause.openingHand;
    _trace('stalled at $turn: seat $seat\'s hand is not open here yet');
  }

  /// After a release: every stalled turn whose seat's secret is known
  /// now moves.
  void _resumeStalled() {
    final d = _deal;
    if (d == null) return;
    for (final e in List.of(_stalled.entries)) {
      // Closed meanwhile some other way — a held seat's audit its own
      // juror said, which carries the secret it was stalled on — and
      // not to be closed a second time. Settled is not enough: a
      // departed person's turn is settled by the removal and still
      // waits here for the move that closes it.
      if (_closedTurns.contains(e.key)) {
        _stalled.remove(e.key);
        continue;
      }
      if (d.awaitsSecret(e.value)) continue;
      // Nor one this side said the game ends at, while that can carry.
      if (_holdsForEnding(e.key)) continue;
      _stalled.remove(e.key);
      _botTurn(e.key, e.value);
    }
    if (_stalled.isEmpty && _pause == Pause.openingHand) _pause = null;
  }

  /// This side's piece of a departed seat's secret, for everyone.
  void _releaseFor(int seat) {
    // Not in a hand that was over before this side was summoned. The
    // key is one of the hand's custodians, and the piece was the
    // client's that served it to say; the table this one follows has
    // long since moved on ([_beforeSummons]).
    if (_beforeSummons(game.handNumber)) return;
    // In the open once the hand is over: the audit publishes every
    // secret then, and a bot seat's piece kept from the players would
    // leave a hand only the jury could check.
    final over = _openingAudit || game.phase == Phase.handOver || game.phase == Phase.gameOver;
    final m = _deal?.releaseShare(seat, inTheOpen: over, only: over ? null : _whoNeedsIt(game.handNumber, seat));
    if (m == null) return;
    _lastReleaseAt = clock.nowMs;
    _emit(EventKind.release, {
      'hand': game.handNumber,
      'about': seat,
      if (m['share'] != null) 'share': m['share'],
      if (m['sealed'] != null) 'sealed': m['sealed'],
    });
  }

  // ---- topping the jury up ----------------------------------------------

  /// The hand's jurors as this side has them: the jury the deal was
  /// sealed to, then whoever has been drawn since, in the juries' own
  /// order ([compareJuries]) and sorted within each. What a held
  /// seat's keys name as its custodians, and so on the record from
  /// there; the list grows after that only as the record names draws
  /// ([_applyGrowth]), since the draws carried here since are this
  /// side's to know, in an order another side may not share.
  List<PublicKey> _custodiansNow(int hand) {
    final drawn = _juriesDrawnFor(hand);
    final dealt = _dealtTo(hand);
    if (drawn.isEmpty && dealt.isEmpty) return const [];
    final out = <PublicKey>[...dealt]..sort();
    for (final d in drawn) {
      for (final k in d.event.jurors.toList()..sort()) {
        if (!out.contains(k)) out.add(k);
      }
    }
    return out;
  }

  /// The jury [hand]'s deal was sealed to: the record's, once it has
  /// said ([_checkSealed]); until then the one this side reads
  /// ([_provisionalDraw]). What the escrow's custodians start from, and
  /// who counts as drawn since. Not simply the first draw by order: the
  /// record may seal the hand to one proposed from a later place.
  List<PublicKey> _dealtTo(int hand) {
    if (_sealedTo.containsKey(hand)) return _juryById(_sealedTo[hand], hand) ?? const [];
    return _provisionalDraw(hand).jurors;
  }

  /// Gives whoever has joined the jury a share of every bot seat's
  /// secret, so that the jury tops back up instead of only shrinking
  /// (docs/04-live-play.md).
  ///
  /// Two holders make a newcomer's share between them, and which two
  /// is not agreed: each sender says what set it weighed its part
  /// against, and the newcomer sums a set once it holds all of it. So
  /// the senders are simply the lowest-indexed custodians still heard
  /// from — mostly the same two everywhere, and where they are not,
  /// the cost is a wait rather than a wrong share.
  void _topUpJury() {
    final d = _deal;
    if (d == null || !spec.sealed) return;
    final hand = game.handNumber;
    // A custodian of a hand over before this side was summoned has the
    // share, read from the record, and no part in the hand: the parts
    // were its earlier client's to make, for a table long past them
    // ([_beforeSummons]).
    if (_beforeSummons(hand)) return;
    final held = botHolders(hand);
    if (held.isEmpty) return;
    // Who this side would have answer, and whether it is one of them.
    // The jury's own liveness, not the table's: _recentWithin reads a
    // key never heard from as recent, which would put the very jurors
    // that went among the senders and leave the newcomer waiting on
    // parts nobody is making.
    final heard = _liveJurors(hand);
    for (final seat in held.keys) {
      if (!d.holdsPieceOf(seat)) continue;
      // By the seat's own list, as the record has grown it
      // ([_applyGrowth]): the place a part is made for is the place
      // its newcomer's piece is weighed at, everywhere.
      final custodians = d.custodiansOf(seat);
      if (custodians == null || custodians.length <= juryToHoldBots) continue;
      final live = [
        for (var i = 1; i <= custodians.length; i++)
          if (heard.contains(custodians[i - 1])) i,
      ];
      final have = live.take(escrowThreshold).toList();
      final mine = custodians.indexOf(signer.publicKey) + 1;
      if (mine < 1 || !have.contains(mine) || have.length < escrowThreshold) continue;
      for (var at = 1; at <= custodians.length; at++) {
        if (have.contains(at) || !_isNewCustodian(hand, custodians[at - 1])) continue;
        final key = '$seat|$at';
        if (clock.nowMs - (_toppedUpAt[key] ?? -topUpEveryMs) < topUpEveryMs) continue;
        final part = d.topUpPart(seat, at: at, have: have);
        if (part == null) continue;
        _toppedUpAt[key] = clock.nowMs;
        topUpsSent++;
        _emit(EventKind.topup, {
          'hand': hand,
          'about': seat,
          'at': at,
          'have': have,
          'from': part['from'],
          'holder': part['holder'],
          'part': part['part'],
        });
      }
    }
  }

  /// Whether this side holds a piece of some bot seat's secret at
  /// [hand] — what a juror brought on is given, and what says the
  /// giving worked.
  bool holdsEscrowPiece(int hand) {
    final d = _dealsByHand[hand];
    if (d == null) return false;
    return botHolders(hand).keys.any(d.holdsPieceOf);
  }

  /// Whether [who] came to the jury after the deal was sealed to it.
  bool _isNewCustodian(int hand, PublicKey who) {
    final dealt = _dealtTo(hand);
    return dealt.isNotEmpty && !dealt.contains(who);
  }

  /// Parts of a new share this side has sent, for a test to look at.
  int topUpsSent = 0;

  /// When this side last sent a part, by seat and index.
  final Map<String, int> _toppedUpAt = {};

  /// Parts heard, by hand, to carry forward to whoever is behind.
  final Map<int, List<TableEvent>> _topUps = {};

  /// How often a part is said again for the same newcomer: a part can
  /// go missing, and the sender never learns whether the set it chose
  /// was the one that completed.
  static const topUpEveryMs = 10000;

  void _onTopUp(TableEvent event) {
    final d = _deal;
    // As a release: kept until there is a deal to put it in.
    if (d == null) return _defer(event);
    if (event.hand > game.handNumber) return _defer(event);
    if (event.hand < game.handNumber) return;
    final about = event.about;
    if (about < 0 || about >= seatCount) return;
    // Kept, and carried forward like a release. A part is a broadcast
    // and its recipient is the one peer most likely to miss it: a
    // juror brought on mid-hand is behind by a whole hand, and may
    // not have been listening at all when the part went out. Whoever
    // carries it forward hands the part over with everything else.
    final kept = _topUps.putIfAbsent(event.hand, () => []);
    if (!kept.any((r) => r.id == event.id)) kept.add(event);
    final at = event.body['at'];
    if (at is! int || at < 1) return;
    // A part made out past the end of the list as this side has it is
    // for a custodian this side has no place for yet — the seat's keys
    // unread, or the play that named the newcomer's draw not yet
    // carried here ([_applyGrowth]). A juror carried the record gets
    // the parts made for it among the very events that say who it is,
    // so this is the ordinary case for the one peer the part is for.
    // That custodian may be this side itself, so a juror keeps it for
    // the drain after each settled turn to try again; anyone else will
    // never be a custodian and drops it.
    //
    // Within the list, this side knows its own place, and only the
    // part made out to that place is any use here. Jurors brought on at
    // several bot seats make a lot of parts, and keeping the others
    // would mean trying each of them again at every turn that settles.
    final mine = d.custodianIndexOf(about);
    if (at > d.custodianCount(about)) {
      _trace('top-up for seat $about at $at, past the ${d.custodianCount(about)} custodians known here');
      return _jurorsOf(event.hand).contains(signer.publicKey) ? _defer(event) : null;
    }
    if (at != mine) return;
    final took = d.acceptTopUpPart({
      'about': about,
      'at': at,
      'have': event.body['have'],
      'from': event.body['from'],
      'holder': event.body['holder'],
      'part': event.body['part'],
    });
    _trace('top-up for seat $about at $at from ${event.body['from']} of ${event.body['have']}: '
        '${!took ? 'refused' : d.holdsPieceOf(about) ? 'the share is whole' : 'kept, waiting on the rest of the set'}');
  }

  // ---- the escrow's custodians, grown on the record ---------------------
  //
  // A held seat's pieces are indexed by each custodian's place in a
  // list: the one the seat's keys named, and after it whoever the
  // hand's later draws bring in. Two draws of one hand can carry in
  // either order, at two sides the one way and the other, and at the
  // verifier in neither; grown as each draw carried, a newcomer given
  // its share at one place would have its piece weighed at another.
  // So the order is the record's, as the draw a deal is
  // sealed to is: a person's own play names the draws that have grown
  // the escrow since the last one that did, and every side grows the
  // list from those plays in the order the record has them, the
  // verifier with it. People's plays, and not every move, because
  // they carry one after another and with an event every time: passes
  // race side by side and settle in a different order at each side,
  // and a bot seat's move settles with nothing said where the seat is
  // everyone's to work out.

  /// The draws named in [hand]'s people's plays so far, in the order
  /// the record names them.
  final Map<int, List<String>> _grown = {};

  /// Who sat down at [seat]: the one key whose plays name the escrow's
  /// growth. Null at a seat that was a bot's from the start.
  PublicKey? _personOf(int seat) {
    final h = spec.seats[seat];
    return h is HumanSeat ? h.key : null;
  }

  /// The draws this side's next play names: the hand's, in the juries'
  /// own order, that bring someone into a held seat's escrow and have
  /// not been named yet.
  List<String> _growthToName(int hand) {
    final d = _dealsByHand[hand];
    final held = botHolders(hand).keys;
    if (d == null || held.isEmpty) return const [];
    final named = {...?_grown[hand]};
    return [
      for (final j in _juriesDrawnFor(hand))
        if (!named.contains(j.event.id) &&
            held.any((s) {
              final c = d.custodiansOf(s);
              return c == null || j.event.jurors.any((k) => !c.contains(k));
            }))
          j.event.id,
    ];
  }

  /// A person's play has carried: the draws it names go on the list.
  void _takeGrowth(int hand, TableEvent play) {
    final named = play.body['grew'];
    if (named is! List) return;
    final list = _grown.putIfAbsent(hand, () => []);
    for (final id in named) {
      if (id is String && !list.contains(id)) list.add(id);
    }
    _applyGrowth(hand);
  }

  /// Grows each held seat's custodians by the draws the record names,
  /// in its order. A draw named and not carried here yet holds up the
  /// ones after it, since a place is a place in the whole list; its
  /// carrying brings it on. Pieces a newcomer released before this
  /// side had it on the list were refused, and are taken again.
  void _applyGrowth(int hand) {
    final d = _dealsByHand[hand];
    final named = _grown[hand];
    if (d == null || named == null) return;
    final added = <PublicKey>[];
    for (final id in named) {
      final jurors = _juryById(id, hand);
      if (jurors == null) break;
      added.addAll(jurors.toList()..sort());
    }
    if (added.isEmpty) return;
    for (final seat in botHolders(hand).keys) {
      final before = d.custodianCount(seat);
      d.extendCustodians(seat, added);
      if (d.custodianCount(seat) == before || !d.awaitsSecret(seat)) continue;
      for (final r in List.of(_releases[hand] ?? const <TableEvent>[])) {
        if (r.about == seat) _onRelease(r);
      }
    }
  }

  /// How long a bot seat's holder has to take the seat's turn, a card
  /// or the pass, at a table of the standard timing; a table's own is
  /// [TableTiming.botActsMs], where the measurement behind it is.
  static final botActsWithinMs = TableTiming.standard.botActsMs;

  /// And its deal steps ([TableTiming.botDealsMs]).
  static final botDealsWithinMs = TableTiming.standard.botDealsMs;

  /// Whether the seat's holder has had the seat's turn in front of it
  /// for longer than that, and said nothing.
  ///
  /// Silence is not the only way a holder fails. One that heartbeats
  /// and does nothing would otherwise hold the seat for as long as it
  /// liked: heard from is not the same as playing.
  ///
  /// A deal step has longer ([TableTiming.botDealsMs]), and its clock waits
  /// for the holder to be at the hand at all. A deal step is the first
  /// thing a holder does in a hand, so it is the one turn a holder can
  /// still be arriving at: drawn this minute, summoned, connecting, and
  /// replaying the record up to it — or replaying a hand given up
  /// undealt, and being carried to the escrow that gave it up. None of
  /// that is idle, and on the table's clock it could eat the whole
  /// allowance before the juror could see the turn, leaving a juror
  /// that was only late out of the next draw ([_letGo]). A play or a
  /// pass comes after the holder's own deal steps, so its holder is at
  /// the hand already.
  ///
  /// And not a turn that is waiting rather than idle: a seat whose
  /// hand is not open here yet is stalled on a secret, which is the
  /// escrow working and not a holder failing.
  bool _outOfTime(int seat) {
    final turn = _openTurnOf(seat);
    if (turn == null || !(turn.isPlay || turn.isPass || turn.isDeal || turn.isAudit)) return false;
    if (_stalled.containsKey(turn)) return false;
    final race = _races[turn];
    if (race == null || race.settled || race.action != null) return false;
    // A deal step that has come and is held here for what vouches for
    // it — the jury it seals to, a draw not yet read ([_onAction]) —
    // has been said. The wait is this side's, not the juror's.
    if ((turn.isDeal || turn.isAudit) && _future.any((e) => e.kind == EventKind.deal && e.turn == turn)) return false;
    // From when the turn became this holder's to take, not from when
    // the turn opened. A turn can open while its seat is still being
    // handed over — a person leaving it, the seat turning into a bot,
    // a juror picking it up from the escrow — and none of that is the
    // holder failing to play. So the clock starts the first time this
    // side sees all of it true at once: the seat a bot's, a holder
    // named for it, the turn open, nothing said, and nothing stalled.
    // A seat that changes hands starts the new holder's clock afresh,
    // which is why the holder is part of the key.
    final holder = botHolders(turn.hand)[seat];
    if (holder == null) return false;
    final key = '$turn|$holder';
    // Nor while this side is behind the table. A peer heard at a later
    // place has seen more settle than this side has, and a turn open
    // here may be one the table took long ago — the holder's move
    // said, and this side's copy of it lost. What is missing then is
    // this side's, not the holder's, and the carry-forward brings it
    // ([_carryForward]); timed meanwhile, a deal step lost on the way
    // to one player would give the hand up at that player alone.
    if (_behind || (turn.isDeal && _arriving(holder, turn.hand))) {
      _botTurnSince.remove(key);
      return false;
    }
    final since = _botTurnSince.putIfAbsent(key, () => clock.nowMs);
    return clock.nowMs - since >= (turn.isDeal || turn.isAudit ? timing.botDealsMs : timing.botActsMs);
  }

  /// Whether a juror has yet to be heard at [hand]: not heard from
  /// since it was drawn — silence covers one that never comes, half a
  /// minute from the draw ([_liveJurors]) — or heard at an earlier
  /// hand and still moving. One whose heartbeats have said the same
  /// earlier place for as long as a deal step may take is not
  /// arriving, it has stopped, the way a person's is ([_catchingUp]).
  bool _arriving(PublicKey juror, int hand) {
    if (juror == signer.publicKey) return false;
    final heard = _jurorHeard[juror];
    final pos = _lastPosition[juror];
    if (heard == null || pos == null) return true;
    for (final d in _juriesFor(hand)) {
      if (d.event.jurors.contains(juror) && heard < (_juryAt[d.event.id] ?? 0)) return true;
    }
    if (pos.$1 >= hand) return false;
    return clock.nowMs - (_positionMovedAt[juror] ?? clock.nowMs) < timing.botDealsMs;
  }

  /// An open turn of a bot seat a juror holds that nobody still being
  /// heard from can take, or null. Its holder would say the move, or,
  /// once the seat is the escrow's, the first of the hand's custodians
  /// still about — and it takes [escrowThreshold] of them to rebuild
  /// the seat between them. With the holder gone and fewer than that
  /// left, the move is not coming from anyone this side can hear.
  ///
  /// A play or a pass. A held seat's deal step owed by a juror that
  /// goes gives the hand up ([_carryEscrow]), and its audit
  /// stalls on the pieces and says so ([_stall]).
  TurnId? _heldTurnNobodyCanTake() {
    final hand = game.handNumber;
    final held = botHolders(hand);
    if (held.isEmpty) return null;
    final live = _liveJurors(hand);
    TurnId? first;
    for (final e in _races.entries) {
      final t = e.key;
      if (e.value.settled || t.hand != hand || !(t.isPlay || t.isPass)) continue;
      final seat = _turnSeat[t];
      if (seat == null || held[seat] == null) continue;
      if (!openableBy(hand, seat, live.contains) && (first == null || _stopsBefore(t, seat, first, _turnSeat[first]!))) first = t;
    }
    return first;
  }

  /// Which of two turns a table stopped at both of names as the one it
  /// is stopped at: the earlier by position, and of a set of turns
  /// open together — the passes, the audits — the lower seat. Every
  /// side names the same one, whatever order it stopped at them in, so
  /// that the people's voices for the game's end meet at one turn
  /// ([_claimEnd]); by the order each side stopped in, two people
  /// stopped at two held seats' audits could each claim the end at a
  /// different one, and neither claim carry.
  static bool _stopsBefore(TurnId a, int seatA, TurnId b, int seatB) {
    if (a.hand != b.hand) return a.hand < b.hand;
    if (a.position != b.position) return a.position < b.position;
    return seatA < seatB;
  }

  /// Whether anyone [up] could open [seat]'s hand at [hand]: a held
  /// seat's own juror, or [escrowThreshold] of the jurors holding a
  /// piece of its secret ([_pieceHolders]); a departed person's, any
  /// one of the jury the deal was sealed to, beside a person's piece.
  /// A hand drawn no jury is escrowed to the people alone, and is no
  /// jury's to lose.
  bool openableBy(int hand, int seat, bool Function(PublicKey) up) {
    if (_juriesDrawnFor(hand).isEmpty) return true;
    final holder = botHolders(hand)[seat];
    final pieces = _pieceHolders(hand, seat).where(up).length;
    if (holder != null) return up(holder) || pieces >= escrowThreshold;
    return pieces >= 1;
  }

  /// Who holds a piece of [seat]'s secret at [hand], as far as this
  /// side can tell: the jury the deal was sealed to, which the seat's
  /// keys split it among, and a juror drawn since once it has been
  /// sent a whole set of parts of one ([_topUpJury]). Not a juror
  /// drawn since that has not: it is on the list of custodians, and
  /// heard from, and holds nothing. A jury drawn after the holders of
  /// the pieces went has nobody to be given them by — a newcomer's
  /// piece is made by [escrowThreshold] of the old — and counting it
  /// would take the seat for one the jury could still open, and sit at
  /// its turn for good.
  Set<PublicKey> _pieceHolders(int hand, int seat) {
    // A person's seat: the custodians its keys named, which is the jury
    // in force when it keyed, whatever draw the hand was sealed to. A
    // hand dealt its bot seats in the open is sealed to no draw at all,
    // and read from that, a leaver's hand would have nobody holding a
    // piece of it, and the game would end over a seat that can be
    // opened.
    if (botHolders(hand)[seat] == null) {
      final named = _dealsByHand[hand]?.custodiansOf(seat);
      if (named != null) return named.toSet();
    }
    final dealt = _dealtTo(hand);
    if (dealt.isEmpty) return const {};
    final custodians = _escrowOrder(hand, seat);
    final out = {...dealt};
    final sets = <String, Set<int>>{};
    for (final e in _topUps[hand] ?? const <TableEvent>[]) {
      if (e.about != seat) continue;
      final at = e.body['at'], from = e.body['from'], have = e.body['have'];
      if (at is! int || from is! int || have is! List || at < 1 || at > custodians.length) continue;
      if (from < 1 || from > custodians.length || custodians[from - 1] != e.author) continue;
      final set = [for (final i in have) if (i is int) i];
      if (set.length < escrowThreshold || !set.contains(from)) continue;
      final got = sets.putIfAbsent('$at|${set.join(',')}', () => {})..add(from);
      if (set.every(got.contains)) out.add(custodians[at - 1]);
    }
    return out;
  }

  /// For a test or a walk: [_pieceHolders].
  Set<PublicKey> pieceHoldersOf(int hand, int seat) => _pieceHolders(hand, seat);

  /// A turn this side is stopped at whose seat nobody it still hears
  /// could open, with the seat, or null: a held seat's play or pass
  /// with its jury gone ([_heldTurnNobodyCanTake]), or a turn stalled
  /// on a seat's secret — a departed person's, or a held seat's at its
  /// audit — that nobody still heard holds enough of.
  ({TurnId turn, int seat})? _unopenable() {
    final hand = game.handNumber;
    final t = _heldTurnNobodyCanTake();
    if (t != null) return (turn: t, seat: _turnSeat[t]!);
    final live = _liveJurors(hand);
    final d = _deal;
    ({TurnId turn, int seat})? first;
    for (final e in _stalled.entries) {
      if (e.key.hand != hand) continue;
      // Open here already, and held for the game's end this side said
      // there ([_holdsForEnding]): not a seat nobody can open.
      if (d != null && d.hand == hand && !d.awaitsSecret(e.value)) continue;
      if (openableBy(hand, e.value, live.contains)) continue;
      if (first == null || _stopsBefore(e.key, e.value, first.turn, first.seat)) first = (turn: e.key, seat: e.value);
    }
    return first;
  }

  /// Why the game ended without finishing, or null while it has not.
  Failure? get failure => _failure;
  Failure? _failure;

  /// The turn it ended at, and the seat nobody could open there.
  ({TurnId turn, int seat})? get failedAt => _failedAt;
  ({TurnId turn, int seat})? _failedAt;

  /// Since when this side has been stopped at [_unopenable]'s turn.
  ({TurnId turn, int since})? _unopenableSince;

  /// How long a table stopped at a seat nobody left can open waits,
  /// saying so, before the game ends ([_judgeQuorum]), at a table of
  /// the standard timing; a table's own is [TableTiming.quorumLostMs].
  static final quorumLostAfterMs = TableTiming.standard.quorumLostMs;

  /// Ends the game when the table has been stopped at one turn, with
  /// nobody left who could move it, for [TableTiming.quorumLostMs]: a seat
  /// nobody left could open ([_unopenable]), or a turn put to a jury
  /// none of whose jurors is left to rule on it ([_unruled]).
  ///
  /// The hand cannot go on, and would be waited on for good; giving it up
  /// and dealing the next would throw away a hand whose cards have
  /// been seen, and enough jurors leaving together could do that to
  /// order. So the game ends — a connection failure, as the player is
  /// told, and unscored. On the record where it can be: the twenty
  /// seconds only propose it, as a clock proposes a boot, and the
  /// people carry it at the turn ([_claimEnd]).
  ///
  /// Only while this side hears most of the table, or once everyone it
  /// does not hear — the people and the hand's jury alike — has been
  /// silent as long as the table gives a person ([_unheardAreGone]). A
  /// device that has lost its own connection hears no juror either,
  /// and that is not the jury gone: the rest remove it for its silence,
  /// and it finds its seat taken when it is back
  /// ([Pause.waitingForPeers] meanwhile). But the last person
  /// left at a table hears nobody, and would wait for good. By the time
  /// the rest have been silent that long it has been removed wherever
  /// they are — or there is nobody else. A juror heard at any time in
  /// those two minutes counts, not only in the last half: one cut off
  /// from this side for less may already have ruled, and its ruling be
  /// on its way — though not one that could not open the seat anyway.
  void _judgeQuorum() {
    final seat = _unopenable();
    final at = seat ?? _unruled();
    if (at == null || !(connectedToMajority || _unheardAreGone(seat))) {
      _unopenableSince = null;
      return;
    }
    // Somebody has claimed the end here already: stopped here too,
    // this side takes its part at once.
    if (_races[at.turn]?.ends.isNotEmpty ?? false) return _claimEnd(at);
    if (_unopenableSince?.turn != at.turn) _unopenableSince = (turn: at.turn, since: clock.nowMs);
    if (clock.nowMs - _unopenableSince!.since < timing.quorumLostMs) return;
    _claimEnd(at);
  }

  /// Whether everyone at the table this side does not hear has been
  /// silent as long as a person is given before the table removes
  /// them — and no juror heard in that time could move the turn it is
  /// stopped at: open [seat], where it waits on one, or else rule.
  bool _unheardAreGone(({TurnId turn, int seat})? seat) {
    if (!participants.every((k) => k == signer.publicKey || _recent(k) || _silent(k))) return false;
    final heard = _liveJurors(game.handNumber, withinMs: silenceAfterMs);
    return seat == null ? heard.isEmpty : !openableBy(game.handNumber, seat.seat, heard.contains);
  }

  /// A turn only the jury can settle — split, or open while this side
  /// hears too few of the table to carry anything, which only a verdict
  /// on the silent can end ([_juryTick]) — with none of the hand's
  /// jurors left to rule on it: none heard from for half a minute, and
  /// none drawn since ([_liveJurors]). A jury drawn again from whoever
  /// is online is live from the draw, so this is a table with nobody
  /// left to draw from, too.
  ///
  /// Read from the turn and from who is heard now, not from the pause
  /// up: a pause for the jury put up while this side was cut off stays
  /// up once it is back, until a decision lands, and by then the turn
  /// may be the people's to settle again.
  ({TurnId turn, int seat})? _unruled() {
    final heard = connectedToMajority;
    for (final e in _races.entries) {
      if (e.value.settled || e.key.hand != game.handNumber) continue;
      if (heard && !e.value.split) continue;
      if (_liveJurors(e.key.hand).isNotEmpty) return null;
      return (turn: e.key, seat: _turnSeat[e.key]!);
    }
    return null;
  }

  /// This side's part in ending the game at [at], where it is stopped
  /// with nobody left to move the table.
  ///
  /// The game's end is the third way a turn can go, beside the move
  /// and the removal, and it is carried the way they are: a majority of
  /// the people at the table, each with one voice at the turn. So this
  /// side claims it — or backs the claim already made — where its voice
  /// at the turn is still its own to give, it hears most of the table,
  /// and enough voices are left that a majority could still say it
  /// ([_endingCanCarry]). Then every side ends at that turn, and every
  /// record says so ([_carryEnded]). A voice already given at the turn
  /// waits for the ending all the same, while it can still carry.
  ///
  /// Where it cannot, the game ends here, for this side alone: nothing
  /// can go on the record without a majority of the people or a jury,
  /// and there is neither — a turn split between the move and a boot
  /// with the jury gone, every voice spent; the last person, who hears
  /// too little of the table to carry anything. It says so, so that a
  /// juror still following stops once every person it hears has ended,
  /// and a person stopped at the same turn does the same. This side's
  /// record then stops at the turn: a record the rest may go on past
  /// only once they have taken it for a player gone silent.
  void _claimEnd(({TurnId turn, int seat}) at) {
    if (_failure != null) return;
    final turn = at.turn;
    final race = _races[turn];
    if (amSeated && !_left && race != null && !race.settled) {
      final mine = race.forEnd.contains(signer.publicKey);
      final free = !mine && !_myWitness.containsKey(turn);
      if (free && connectedToMajority && _endingCanCarry(turn)) {
        if (race.ends.isEmpty) {
          _trace('stopped at $turn for ${timing.quorumLostMs ~/ 1000} seconds: nobody left can move it (seat ${at.seat}); '
              'claiming the game\'s end there');
          _endedWord = _say(EventKind.ended, {'hand': turn.hand, 'turn': turn.index, 'seat': at.seat, 'vote': true});
        } else {
          _trace('stopped at $turn too, with nobody left to move it: backing the claim that the game ends there');
          _witness(turn, race.ends.first);
        }
        return;
      }
      if ((mine || connectedToMajority) && _endingCanCarry(turn)) return;
    }
    // Nothing this side can put on the record: the game ends here.
    if (amSeated && !_left && _endedWord == null) {
      _endedWord = _say(EventKind.ended, {'hand': turn.hand, 'turn': turn.index, 'seat': at.seat, 'vote': false});
    }
    _endHere(at);
  }

  /// Signs, sends by every road and takes one event of this side's own,
  /// and hands it back.
  TableEvent? _say(EventKind kind, Map<String, Object?> body) {
    if (_failure != null) return null;
    final e = TableEvent.sign(signer, table: spec.id, kind: kind, body: body);
    _trace('emit ${kind.name} $body');
    transport.broadcast(e.toJson(), everywhere: true);
    _accept(e);
    return e;
  }

  /// Whether a majority of the people at [turn] could still say the game
  /// ends there: those who have, and those whose voice at the turn is
  /// not known to have gone elsewhere — to the move, to a removal, to
  /// another move for a bot seat, or to a turn after this one
  /// ([_votedPast]) — and who have been heard from in the silence a
  /// person is given. Nobody silent that long is a vote still coming,
  /// as a split counts them ([_settle]): counted, a claim would wait on
  /// the gone for good.
  ///
  /// Nor is anybody who has ended the game for itself, with its word
  /// rather than a vote here: it says nothing more, and counted, the
  /// last person at a table of two would wait for good on a vote from
  /// somebody who has already gone.
  bool _endingCanCarry(TurnId turn) {
    final race = _races[turn];
    if (race == null) return false;
    final of = _participantsAt(turn);
    final spent = {
      ...race.forAction,
      ...race.forRemoval,
      for (final w in race.forRival.values) ...w,
      ..._ended.difference(race.forEnd),
    };
    final past = _votedPast(turn);
    final could = of.where((k) =>
        race.forEnd.contains(k) ||
        (!spent.contains(k) && !past.contains(k) && !_standsPast(k, turn) && (k == signer.publicKey || !_silent(k))));
    return could.length >= _majority(of);
  }

  /// Whether [key] says, by where its heartbeat puts it, that it has
  /// closed [turn]: every turn of the turn's set behind it. A side that
  /// has closed a turn never backs the game's end there
  /// ([_onEndedClaim]), so its voice at the turn is not one the end can
  /// have — and a side waiting on it past the turn is a side waiting on
  /// this one: where the next turn is this side's own, holding would
  /// have it put out for its silence there.
  bool _standsPast(PublicKey key, TurnId turn) {
    final at = _lastPosition[key];
    if (at == null || key == signer.publicKey) return false;
    return at.$1 > turn.hand || (at.$1 == turn.hand && at.$2 >= _stepOf(turn) + _setOf(turn).length);
  }

  /// The people this side holds a vote from at a turn after [turn]: a
  /// move, a witness or a claim of theirs held back for a turn this
  /// side has not reached. Their voice there is spent on the table
  /// going on, and a majority for ending the game at [turn] must not
  /// count it.
  Set<PublicKey> _votedPast(TurnId turn) => {
        for (final e in _future)
          if (_humans.contains(e.author) && _votes(e) && _pastTurn(e, turn)) e.author,
      };

  static bool _votes(TableEvent e) => switch (e.kind) {
        EventKind.witness || EventKind.pass || EventKind.play || EventKind.deal => true,
        EventKind.boot || EventKind.absent || EventKind.escrow || EventKind.ended => true,
        _ => false,
      };

  static bool _pastTurn(TableEvent e, TurnId turn) {
    try {
      final t = e.turn;
      return t.hand > turn.hand || (t.hand == turn.hand && t.position > turn.position);
    } catch (_) {
      return false;
    }
  }

  /// Whether this side is holding [turn] for the game's end: it backed
  /// the end there, and the ending could still carry. A departed seat's
  /// move is worked out by every side once its hand opens, with nothing
  /// said and nobody asked; one that opened here after this side had
  /// said the game ends at that turn, taken, would put this side past
  /// the turn while its voice went to a majority that ends the game at
  /// it — one voice on two outcomes, and two records. So it waits,
  /// until the ending carries or can no longer ([_endingCanCarry]).
  bool _holdsForEnding(TurnId turn) {
    final race = _races[turn];
    return race != null && !race.settled && race.forEnd.contains(signer.publicKey) && _endingCanCarry(turn);
  }

  /// The game ends here for this side alone ([_claimEnd]).
  void _endHere(({TurnId turn, int seat}) at) {
    if (_failure != null) return;
    _trace('the game ends here at ${at.turn}, ${Failure.jurorQuorumLost.label}; not on the record: '
        'nobody left could carry it');
    _failure = Failure.jurorQuorumLost;
    _failedAt = at;
    _pause = null;
    _notify();
  }

  /// A majority of the people at [turn] said the game ends there: it
  /// does, on this side's record as on everyone's.
  void _carryEnded(TurnId turn, _Race race, TableEvent claim, Set<PublicKey> of) {
    race.settled = true;
    _log(Decision(turn: turn, event: claim, witnesses: {...race.forEnd}, removal: true, among: of));
    _endedAt = turn;
    _trace('the game ends at $turn, ${Failure.jurorQuorumLost.label}: carried by ${race.forEnd.intersection(of).length}');
    _failure = Failure.jurorQuorumLost;
    _failedAt = (turn: turn, seat: _turnSeat[turn]!);
    _pause = null;
    _notify();
  }

  /// The turn the record ends the game at, where it does.
  TurnId? _endedAt;

  /// This side's word that the game ended for it, and when it last
  /// said it.
  TableEvent? _endedWord;
  int _endedSaidAt = 0;

  /// An ended side says nothing new. To anyone still talking to it — a
  /// juror still serving, a person still playing — it says again, no
  /// more than every ten seconds, how it ended: the claims and the
  /// backing that carried the end where the record holds it, which a
  /// side behind takes as it takes any turn it is carried; or else its
  /// own word.
  void _answerEnded(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind != EventKind.heartbeat.name && kind != EventKind.serve.name) return;
    if (clock.nowMs - _endedSaidAt < 10000) return;
    final at = _endedAt;
    final race = at == null ? null : _races[at];
    final word = _endedWord;
    if (race == null && word == null) return;
    _endedSaidAt = clock.nowMs;
    if (race != null) {
      for (final e in [...race.ends, ...race.witnessEvents.where((w) => race.ends.any((c) => c.id == w.witnessed))]) {
        transport.broadcast(e.toJson(), everywhere: true);
      }
    } else {
      transport.broadcast(word!.toJson(), everywhere: true);
    }
  }

  /// The people who have said the game ended for them ([_claimEnd]).
  final Set<PublicKey> _ended = {};

  /// A person's claim that the game ends at a turn, or their word that
  /// it has ended for them: a vote in the turn's race where it says it
  /// is one, carried as a boot is ([_settle]), and taken by a side
  /// stopped at the same turn as its cue to take its own part
  /// ([_claimEnd]). A juror stops once the record ends the game, or
  /// once every person it still hears has said so: there is nobody
  /// left to serve.
  void _onEndedClaim(TableEvent event) {
    if (!_humans.contains(event.author)) return;
    _ended.add(event.author);
    _jurorStopsIfAllEnded(event);
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    final race = _races[turn];
    if (race == null && where == 0) return _defer(event); // current, and not open yet
    if (race == null || race.settled || where < 0) {
      if (race != null && _lateEndingAt(turn)) _takeLateEnding(turn, race, event);
      return;
    }
    if (event.seat != _turnSeat[turn] || !_participantsAt(turn).contains(event.author)) return;
    if (!race.ends.any((e) => e.id == event.id)) race.ends.add(event);
    if (event.body['vote'] == true) {
      race.forEnd.add(event.author);
      if (event.author == signer.publicKey) _myWitness[turn] = event.id;
    }
    race.forEnd.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    _settle(turn);
    if (event.author == signer.publicKey || _failure != null || !amSeated || _left) return;
    final at = _unopenable() ?? _unruled();
    if (at != null && at.turn == turn && (connectedToMajority || _unheardAreGone(_unopenable()))) _claimEnd(at);
  }

  void _jurorStopsIfAllEnded(TableEvent event) {
    if (mySeat != null || _failure != null) return;
    if (!participants.every((k) => _ended.contains(k) || _silent(k))) return;
    _trace('everyone at the table has ended the game; nothing left to serve');
    _failure = Failure.jurorQuorumLost;
    _failedAt = (turn: event.turn, seat: event.seat);
    _notify();
  }

  /// Whether the game's end at [turn] is still to be taken here although
  /// the turn has settled here: by a departed seat's move worked out
  /// once its hand opened here, where the rest never saw it open and
  /// ended the game at that turn. Nothing past it has carried here —
  /// not while the rest had gone — and nothing has been recorded after
  /// it, so this side's record is the table's up to the turn, and the
  /// end is taken there ([TurnState.ended]).
  bool _lateEndingAt(TurnId turn) {
    if (_failure != null || _removedAtTurn.contains(turn) || _onRecord.contains(turn)) return false;
    final race = _races[turn];
    if (race == null || !race.settled) return false;
    return !record.any((d) => d.turn.hand > turn.hand || (d.turn.hand == turn.hand && d.turn.position > turn.position));
  }

  void _takeLateEnding(TurnId turn, _Race race, TableEvent claim) {
    if (claim.seat != _turnSeat[turn] || !_participantsAt(turn).contains(claim.author)) return;
    if (!race.ends.any((e) => e.id == claim.id)) race.ends.add(claim);
    if (claim.body['vote'] == true) race.forEnd.add(claim.author);
    race.forEnd.addAll(_earlyWitnesses.remove(claim.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(claim.id) ?? const []);
    _settleLateEnding(turn);
  }

  /// The game's end at [turn], settled here by a move worked out first,
  /// once a majority is seen behind it ([_lateEndingAt]).
  void _settleLateEnding(TurnId turn) {
    final race = _races[turn]!;
    final of = _participantsAt(turn);
    if (race.forEnd.intersection(of).length < _majority(of)) return;
    _trace('the game ended at $turn elsewhere, where this side had worked the turn out: taken');
    _carryEnded(turn, race, race.ends.first, of);
  }

  /// Whether the pause up is this side's word that a held seat has
  /// nobody left to play it, so that it comes down when somebody is.
  bool _waitingOnGoneJury = false;

  /// The held seat this side has stopped at with nobody left to play
  /// it, while it is saying so; null otherwise. For a view, and for
  /// the chaos walk to hold the table to its word.
  ({TurnId turn, int seat})? get waitingOnGoneJury {
    if (!_waitingOnGoneJury) return null;
    final t = _heldTurnNobodyCanTake();
    return t == null ? null : (turn: t, seat: _turnSeat[t]!);
  }

  /// Every juror [hand]'s bot seats could be escrowed to, as this side
  /// has heard them drawn ([_custodiansNow]); a seat's own list, in
  /// the escrow's order, is [escrowOrderOf].
  List<PublicKey> custodiansOf(int hand) => _custodiansNow(hand);

  /// [seat]'s custodians at [hand], in the escrow's order: for a test.
  List<PublicKey> escrowOrderOf(int hand, int seat) => _escrowOrder(hand, seat);

  /// Every juror of [hand] as this side has them: each jury drawn for
  /// it, and the one this side serves in.
  Set<PublicKey> jurorsOf(int hand) => _jurorsOf(hand);

  /// The turns stalled on a seat's secret, with the seat each waits on.
  Map<TurnId, int> get stalled => Map.unmodifiable(_stalled);

  /// Jurors this side took a seat off for having the turn and not
  /// playing it — not for going quiet, which the draw already leaves
  /// out ([_proposeJury]).
  final Set<PublicKey> _letGo = {};

  /// When each bot seat's turn became its holder's to take, by turn
  /// and holder. Cleared with the hand, and small in it: one entry per
  /// turn a bot seat is on.
  final Map<String, int> _botTurnSince = {};

  /// A held seat's juror out at the seat's open turn, by this side's
  /// clocks: claimed for the escrow ([_onEscrow]), as a person's seat
  /// is booted. Only a person at the table claims, and only at the
  /// seat's own turn; a juror follows the record. Nothing is given up
  /// here on this side's word alone.
  ///
  /// A bot seat whose juror has gone quiet, or sits on its turn, is a
  /// seat nobody is playing, so it is given up to the escrow like a
  /// departed person's: any [escrowThreshold] of the jury's pieces
  /// rebuild its secret ([_botActsHere], docs/04-live-play.md).
  ///
  /// To the jury alone. A departed person's piece goes out in the
  /// clear, because the hand it opens was that person's own and the
  /// table is entitled to check it; a bot seat's is sealed to the
  /// custodians ([_releaseFor]), because the hand it opens is nobody's
  /// and a player that could read it would be reading its own
  /// opponents. So the pieces pass the table unreadable, the jurors
  /// that hold them open the seat between themselves, and the first
  /// of them still about says the seat's moves ([_firstToSay]) while
  /// every other side takes what it says on the record.
  void _claimEscrows() {
    if (!amSeated || _left || done || !connectedToMajority || writesRefused) return;
    final hand = game.handNumber;
    for (final e in botHolders(hand).entries) {
      final seat = e.key;
      if (_isEscrowed(hand, seat)) continue;
      final turn = _openTurnOf(seat);
      if (turn == null) continue;
      if (turn.isDeal && turn.dealRound == 0 && !_sealedTo.containsKey(hand)) continue;
      final race = _races[turn]!;
      if (race.action != null || _myWitness.containsKey(turn)) continue;
      if (!_jurorOut(seat)) continue;
      final quiet = !_liveJurors(hand).contains(e.value);
      _trace('bot seat $seat: its juror ${e.value.substring(0, 4)} '
          '${quiet ? 'has gone quiet' : 'has had the turn too long and said nothing'}; claimed for the escrow at $turn');
      _emit(EventKind.escrow, {'hand': turn.hand, 'turn': turn.index, 'seat': seat}, everywhere: true);
    }
  }

  /// Every open turn of [seat] offered to the bot here. For a seat
  /// that has just changed hands: a turn is only offered as it opens,
  /// and one already open when the seat was given up would be offered
  /// to nobody.
  void _takeUpSeat(int seat) {
    for (final e in _races.entries.toList()) {
      // Not one a move has already been made at. A given-up seat is
      // offered again every tick ([_releaseTick]), and the juror whose
      // place it is to say the seat's move would otherwise say it
      // again at every one of them.
      if (e.value.settled || e.value.action != null) continue;
      if (_turnSeat[e.key] == seat) _botTurn(e.key, seat);
    }
  }

  /// Every few seconds while any departed seat's secret is awaited
  /// here: say this side's pieces again, since a release lost is a
  /// table stalled.
  void _releaseTick() {
    _claimEscrows();
    final d = _deal;
    if (d == null) return;
    // A turn held for the game's end whose ending can no longer carry
    // is let go of here, once the rest have gone on past it
    // ([_holdsForEnding]).
    if (_stalled.isNotEmpty) _resumeStalled();
    // A given-up seat's open turn, offered again. The juror whose
    // place it is to say the move may not have been able to when the
    // seat opened, and the one ahead of it may since have gone.
    final held = botHolders(game.handNumber);
    for (final seat in d.gone) {
      if (held.containsKey(seat)) _takeUpSeat(seat);
    }
    // The hand is over: every secret still sealed to the jury goes out
    // in the open, once, whatever the gap since the last piece was
    // said. The audit cannot close without them — a player has no
    // piece of a bot seat and never will — and this side is about to
    // move on to the next hand, after which it would never think to
    // say them at all.
    if (_openingAudit || game.phase == Phase.handOver || game.phase == Phase.gameOver) _sayOpenReleases();
    if (clock.nowMs - _lastReleaseAt < 5000) return;
    for (final s in d.gone) {
      if (d.awaitsSecret(s)) _releaseFor(s);
    }
  }

  void _onRelease(TableEvent event) {
    final d = _deal;
    // Before there is a deal to put it in. A juror summoned mid-hand
    // is handed the record as it stands, and the pieces of a seat
    // already given up come with it — read before the deal they
    // belong to has been built here. Dropped, they would be dropped for
    // good: the id is seen, and every copy said again after it is
    // ignored. So the piece waits instead, and the drain that follows
    // each settled turn brings it back once the deal exists.
    if (d == null) return _defer(event);
    if (event.hand > game.handNumber) return _defer(event);
    if (event.hand < game.handNumber) return;
    final about = event.about;
    if (about < 0 || about >= seatCount) return;
    // For a seat still here as far as this peer knows: kept for when
    // its removal lands.
    if (!d.gone.contains(about)) return _defer(event);
    final kept = _releases.putIfAbsent(event.hand, () => []);
    if (!kept.any((r) => r.id == event.id)) kept.add(event);
    final was = d.awaitsSecret(about);
    d.acceptRelease({
      'about': about,
      'holder': event.author,
      'share': event.body['share'],
      'sealed': event.body['sealed'],
    });
    if (was && !d.awaitsSecret(about)) {
      _trace('seat $about\'s hand is open, from ${event.author.substring(0, 4)}\'s piece and another');
      _resumeStalled();
      // The hand may have been waiting on this very secret to know who
      // leads: a seat removed before it declared takes its word with it,
      // and the card is found in the hand the escrow just opened.
      _advanceDeal();
      _actOnDeal();
      _notify();
    }
  }


  /// A turn whose race no participant can still carry, waiting for the
  /// jury; null when there is none.
  TurnId? get stuckSplit {
    for (final e in _races.entries) {
      if (!e.value.settled && e.value.split) return e.key;
    }
    return null;
  }

  /// Whether this peer has heard from a majority of the participants
  /// lately — itself included. A peer that has not is the one cut off,
  /// and has no business removing anyone.
  bool get connectedToMajority => heardLately.length >= _majority(participants);

  /// The participants heard from within a couple of heartbeats, this
  /// peer among them: who is here, as against who has a seat.
  Set<PublicKey> get heardLately => {
        for (final k in participants)
          if (k == signer.publicKey || _recent(k)) k,
      };

  /// Heard from within a couple of heartbeats.
  bool _recent(PublicKey key) => clock.nowMs - (_lastHeard[key] ?? clock.nowMs) < heartbeatMs * 2 + 2000;

  void _remove(int seat, {required TurnId at, required EventKind how}) {
    final holder = holders[seat];
    if (holder is HumanSeat) {
      _removedAt[holder.key] = at;
      _removedHow[holder.key] = how;
      holders[seat] = BotSeat(spec.replacementFor(seat));
      // The seat's own open turn, if any, is settled by this removal.
      final open = _openTurnOf(seat);
      if (open != null) _removedAtTurn.add(open);
      // At a sealed table the seat's secret is now everyone's to
      // rebuild, from the pieces it escrowed; this side gives its.
      final d = _deal;
      if (d != null) {
        d.seatLeft(seat);
        _releaseFor(seat);
        _drainFuture();
      }
      // A removal placed in an earlier hand changes which seats this
      // hand's jury holds, and it can arrive long after the hand was
      // dealt ([_refixHolders]). One placed in this hand changes
      // nothing — that seat is not the jury's to hold in the hand it
      // is given up in — so the check costs a comparison and the
      // rebuild does not happen.
      _refixHolders(game.handNumber);
    }
  }

  // ---- the leave, on the record -----------------------------------------
  //
  // A leave is its author's own word, made where they stood ([leave]),
  // and carried as a boot is: the people at the table back it as it
  // reaches them, and a majority of them at its turn carries it, the
  // leaver's signature its own vote. Each person backs one way out of a
  // seat — a leave, or a boot or a claim of silence at the seat's turn
  // — so a leave and a boot at one seat cannot both carry, and every
  // record, the jury's too, says the same one.
  //
  // Taken wherever it arrived instead, a side that had booted the seat
  // would pass over the leave and one that had the leave over the
  // boot, and records would keep different exits. Settling it at the
  // seat's own next turn, as a boot is, would stop a table
  // of two people dead — every turn needs both of them, and the
  // leaver's next turn cannot come until the ones before it carry — and
  // would deal the hand after a leave made between hands with the
  // leaver's cards open to the table, a seat given up at its keys.

  /// Leaves heard, by id, with who backs each.
  final Map<String, _Leave> _leaves = {};

  /// The leave this side has backed, by the leaver's key: its voice on
  /// that seat's way out, given ([_mayBackBoot]).
  final Map<PublicKey, String> _leaveBacked = {};

  /// The turn of the boot or claim of silence this side has backed, by
  /// the key of the person it would remove ([_mayBackLeave]).
  final Map<PublicKey, TurnId> _bootBacked = {};

  /// Who has backed each person's leave, by the leaver's key, whether
  /// or not the leave itself has been heard here: none of them will
  /// back a boot of the seat ([_settle]).
  final Map<PublicKey, Set<PublicKey>> _leaveBackers = {};

  void _onLeave(TableEvent event) {
    final seat = event.seat;
    if (seat < 0 || seat >= seatCount) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != event.author) return;
    if (_compare(event.turn) > 0) return _defer(event);
    final claim = _leaves.putIfAbsent(event.id, () => _Leave(event));
    claim.backers.add(event.author);
    claim.backers.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    claim.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    _trace('leave by seat $seat at ${event.turn}');
    _backLeave(claim);
    _settleLeave(claim);
  }

  /// Backs [claim], once, if this side is at the table at its turn and
  /// has not backed another way out of the seat. Nothing to judge: it
  /// is the leaver's own word.
  void _backLeave(_Leave claim) {
    final e = claim.event;
    if (!amSeated || _left || e.author == signer.publicKey) return;
    if (!_mayBackLeave(e.author)) return;
    if (!_participantsAt(e.turn).contains(signer.publicKey)) return;
    _leaveBacked[e.author] = e.id;
    final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
      'event': e.id,
      'hand': e.turn.hand,
      'turn': e.turn.index,
      'seat': e.seat,
      'leave': true,
    });
    transport.broadcast(w.toJson(), everywhere: true);
    _accept(w);
  }

  /// Whether this side's voice on [person]'s way out is free for their
  /// leave: not given to a boot or a claim of silence that could still
  /// carry. One whose turn settled with the seat still here lost.
  bool _mayBackLeave(PublicKey person) {
    if (_leaveBacked.containsKey(person)) return false;
    final boot = _bootBacked[person];
    return boot == null || (_races[boot]?.settled ?? true);
  }

  /// Whether this side may back a boot or a claim of silence against
  /// [person]: not once it has backed their leave.
  bool _mayBackBoot(PublicKey person) => !_leaveBacked.containsKey(person);

  void _onLeaveWitness(TableEvent event) {
    final id = event.witnessed;
    final leaver = event.seat >= 0 && event.seat < seatCount ? _personOf(event.seat) : null;
    if (leaver != null && leaver != event.author) {
      if (_leaveBackers.putIfAbsent(leaver, () => {}).add(event.author)) {
        // A turn at the seat waiting on this voice may be split now.
        for (final e in List.of(_races.entries)) {
          if (!e.value.settled && _turnSeat[e.key] == event.seat) _settle(e.key);
        }
      }
    }
    final claim = _leaves[id];
    if (claim == null) {
      // For a leave not heard yet: kept by its id, as a jury's are.
      _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
      _earlyWitnessEvents.putIfAbsent(id, () => []).add(event);
      return;
    }
    if (claim.backers.add(event.author)) claim.witnessEvents.add(event);
    _settleLeave(claim);
  }

  /// Carries [claim] once a majority of the people at its turn back
  /// it: the seat is a bot's from there, as a boot would leave it.
  void _settleLeave(_Leave claim) {
    if (claim.carried) return;
    final e = claim.event;
    final seat = e.seat;
    final holder = holders[seat];
    // Gone some other way first: a boot carried at its turn.
    if (holder is! HumanSeat || holder.key != e.author) return;
    final turn = e.turn;
    final of = _participantsAt(turn);
    if (!of.contains(e.author) || claim.backers.intersection(of).length < _majority(of)) return;
    claim.carried = true;
    _log(Decision(turn: turn, event: e, witnesses: {...claim.backers}, among: of, removal: true));
    _trace('left seat $seat at $turn by ${claim.backers.intersection(of).length} of ${of.length}');
    _remove(seat, at: turn, how: EventKind.leave);
    final open = _openTurnOf(seat);
    if (open != null) {
      _races[open]!.settled = true;
      _botTurn(open, seat);
    }
    _reconsider();
  }

  bool _silent(PublicKey key) => clock.nowMs - (_lastHeard[key] ?? clock.nowMs) >= silenceAfterMs;

  // ---- silence -----------------------------------------------------------
  //
  // A seat silent past [silenceAfterMs] is booted at its own turn
  // without waiting on its clock, and nowhere else. A claim made at
  // whatever position a peer is on would be applied to an open turn at
  // different moments by different peers, and two claims in flight at
  // once — each about a seat that had voted at that turn — could let
  // two peers settle the turn opposite ways, each with a majority of
  // the set it believed in. A removal made at the seat's own turn is
  // the race's own decision, and
  // a seat removed that way has no later votes for anyone to disagree
  // about. The stuck turn goes to the jury instead (_settle).

  /// A pause for the jury or for peers lifts when a decision lands;
  /// the deal's own — a hand being opened from escrow, a lead nobody
  /// declared — lift on their own conditions.
  void _liftPause() {
    if (_pause == Pause.waitingForJury || _pause == Pause.waitingForPeers) _pause = null;
  }

  /// After a departure: a proposal that could not carry may carry now.
  void _reconsider() {
    _liftPause();
    for (final turn in List.of(_races.keys)) {
      if (!_races[turn]!.settled) _settle(turn);
    }
    // A leave is a majority of fewer people once someone else has gone.
    for (final claim in List.of(_leaves.values)) {
      _settleLeave(claim);
    }
    _notify();
  }

  // ---- timers -------------------------------------------------------------

  void _heartbeat() {
    if (_closed || _failure != null) return;
    // The next one is booked before this one is sent — a send that
    // throws must not end the heartbeat for good — and behind a peer
    // heard lately, every second, since a heartbeat is what brings the
    // missing turns.
    _timers.add(clock.schedule(_behind ? 1000 : heartbeatMs, _heartbeat));
    heartbeatsSent++;
    // Every sixth — half a minute at the usual pace — goes by every
    // path: a peer or a juror that cannot read the relay this device
    // writes to still hears it alive, well inside the silence that
    // would let it be booted.
    final everywhere = heartbeatsSent % 6 == 0;
    // And each says which paths this peer reads, so that a writer can
    // pick one it can hear (transport.dart).
    if (amSeated && !_left) {
      _emit(EventKind.heartbeat, {'hand': game.handNumber, 'step': step, 'reads': transport.paths}, everywhere: everywhere);
    } else if (mySeat == null && _serving.isNotEmpty && !done) {
      _emit(EventKind.serve, {'hand': game.handNumber, 'step': step, 'serving': _serving.keys.toList(), 'reads': transport.paths},
          everywhere: everywhere);
    }
  }

  /// Heartbeats sent so far, for a log.
  int heartbeatsSent = 0;

  /// Events held for a position not yet reached, for a log.
  int get deferred => _future.length;

  bool get _behind => _lastPosition.entries.any((e) {
        if (!_recent(e.key)) return false;
        final (hand, step) = e.value;
        return hand > game.handNumber || (hand == game.handNumber && step > this.step);
      });

  /// Once a second: boot anyone silent too long whose turn it is,
  /// re-check boots this peer held back on until its own clock agreed,
  /// and repeat what is still unsettled — a message lost to a partition
  /// or a reconnect is recovered by whoever still holds it.
  void _tick() {
    if (_closed || _failure != null) return;
    // Before either branch: a hand's deal can be deferred waiting on
    // its jury, and the peer that has to come back to it is not always
    // a seated one or a serving one — a client that has left the table
    // still follows the hands out, and is in neither branch below.
    _startDealWhenReady();
    _forgetSaidAgain();
    _topUpJury();
    _timers.add(clock.schedule(1000, _tick));
    if (amSeated && !_left && !done) {
      _repeat();
      // Cut off from the table? Say so, rather than claim anything.
      final stuck = _races.values.any((r) => !r.settled);
      if (!connectedToMajority && stuck && _pause == null) {
        _pause = participants.length <= 2 ? Pause.waitingForJury : Pause.waitingForPeers;
      } else if (connectedToMajority && _pause == Pause.waitingForPeers && !_races.values.any((r) => r.forRemoval.isNotEmpty)) {
        _pause = null;
      }
      // Stopped at a bot seat nobody left can take? Say that too. A
      // player never says a held seat's move — the jury does — so a
      // table whose jury has gone reaches the seat's turn and waits,
      // and without this it would wait with nothing on the screen.
      //
      // Taking over a pause for the jury already up, too: one put up
      // while this side was cut off stays up after it is back (a
      // decision landing is what lifts it), and a table that is back
      // and stopped here is waiting for this, not for that.
      final waits = _heldTurnNobodyCanTake();
      if (waits != null && (_pause == null || _pause == Pause.waitingForJury)) {
        if (!_waitingOnGoneJury) {
          _trace('stopped at $waits: bot seat ${_turnSeat[waits]} has nobody left to play it; waiting for the jury');
        }
        _pause = Pause.waitingForJury;
        _waitingOnGoneJury = true;
      } else if (waits == null && _waitingOnGoneJury) {
        _waitingOnGoneJury = false;
        if (_pause == Pause.waitingForJury && !_races.values.any((r) => !r.settled && r.split)) _pause = null;
      }
      // And stopped there, or at a departed seat's hand, for as long as
      // a silent person is given: the game ends ([_judgeQuorum]).
      _judgeQuorum();
      if (_failure != null) return;
      // Anyone not heard from for two minutes whose turn is open is
      // booted at once, for silence.
      for (final e in List.of(_races.entries)) {
        final race = e.value;
        if (race.settled || race.action != null || _myWitness.containsKey(e.key)) continue;
        final seat = _turnSeat[e.key]!;
        final h = holders[seat];
        if (h is! HumanSeat || h.key == signer.publicKey || !_isParticipant(h.key)) continue;
        if (!_silent(h.key) || !connectedToMajority || writesRefused) continue;
        if (!_mayBackBoot(h.key)) continue;
        _emit(EventKind.absent, {'hand': e.key.hand, 'turn': e.key.index, 'seat': seat}, everywhere: true);
      }
      // Boots this peer held back on until its own clock agreed; and
      // every voted race looked at again, since a deadlock can arrive
      // by silence alone, with no new message to prompt it.
      for (final e in List.of(_races.entries)) {
        final race = e.value;
        if (race.settled) continue;
        if (race.boots.isNotEmpty && !_myWitness.containsKey(e.key)) _considerCountersigning(e.key, race.boots.first);
        if (race.action != null || race.boots.isNotEmpty) _settle(e.key);
      }
      _juryTick();
      _bootLiars();
      _actOnDeal();
      _releaseTick();
    } else if (mySeat == null && _serving.isNotEmpty && !done) {
      // Its own again, every couple of seconds, while a turn it spoke
      // for stands unsettled. A bot seat's holder is that seat's only
      // voice, and nothing else would come back to a step of the deal
      // it said once that went missing on the way to one peer —
      // [_actOnDeal] skips a turn that already has this side's action
      // on it, the carry-forward carries only what has settled
      // somewhere, and a table waiting on a deal turn is neither split
      // nor paused, so nobody appeals. A juror holding a seat is as
      // much that seat as a person is theirs ([_repeat]).
      _repeat(ownOnly: true);
      _judgeAppeals();
      // A juror holding a bot seat owes that seat's deal steps, and
      // owes them again whenever the last look found it too early to
      // take one (docs/04-live-play.md). The hand's deal may have been
      // too early to build as well — the jury that holds its bot seats
      // settles a moment after the hand opens — and nothing else here
      // would ever come back to it.
      _startDealWhenReady();
      _actOnDeal();
      _releaseTick();
    }
    _notify();
  }

  int _repeatTick = 0;

  /// How long to wait before saying an unsettled turn again, in
  /// seconds, by how many times it has been said already.
  static int _repeatGap(int repeats) => repeats >= 4 ? 30 : 2 << repeats;

  /// Whether [turn] is old enough for a peer to say somebody *else's*
  /// action again.
  ///
  /// A seat says its own action again after two seconds, because a
  /// dropped message is the ordinary reason a turn has not settled.
  /// Everyone else carrying it at two seconds as well would make it the
  /// largest single item on the wire: at a sealed table, six parties
  /// each repeating a twelve-kilobyte shuffle argument, and the relay
  /// handing every copy to all six, for a case that has not happened
  /// yet (service/tool/wire_over_socket.dart).
  ///
  /// Carrying is for the case it was built for: a table cut in two, or
  /// a relay that takes one peer's events and not another's, where the
  /// only way the far side hears an action is from somebody who is not
  /// its author (matrix_test.dart). What makes that case urgent is
  /// the boot clock, so the boot clock is what the wait is measured
  /// against: halfway to the turn's own allowance, which leaves as long
  /// again for the carried copy to arrive and be witnessed before
  /// anybody can call the seat silent. Three seconds for a play whose
  /// bank is spent, more for a pass or a seat with time in hand.
  ///
  /// Except a deal turn or an audit, which is [_dealCarryMs]. Their
  /// allowance is how long a slow device may take to work a step out,
  /// forty seconds, and half of that is twenty seconds of a table cut
  /// in two sitting on a step that was said in the first second. A
  /// copy needs no longer to arrive because its author was slow.
  bool _carryDue(TurnId turn) {
    final opened = _openedAt[turn];
    final seat = _turnSeat[turn];
    if (opened == null || seat == null) return true;
    final wait = timeBank.banks(turn) ? _allowanceMs(turn, seat) ~/ 2 : _dealCarryMs;
    return clock.nowMs - opened >= wait;
  }

  /// When a deal turn's or an audit's action may be said again by
  /// someone other than its author: seven and a half seconds, well
  /// inside the forty those turns are allowed.
  static const _dealCarryMs = 7500;

  /// [ownOnly] leaves out the carrying — somebody else's action said
  /// again for a peer that may not have heard it. That is a seat's
  /// job, done against the boot clock ([_carryDue]), and a jury of six
  /// doing it as well would put six copies of a twelve-kilobyte
  /// shuffle argument on the relay for a case that has not happened.
  /// A juror still says its own again, because the seat it holds has
  /// no other voice.
  void _repeat({bool ownOnly = false}) {
    if (++_repeatTick % 2 != 0) return;
    // What stays unsettled is said again — the first time after two
    // seconds, by the usual path; the second time, and every tenth
    // second after, by every path. An action settles in a moment when
    // everyone heard it, so one still open after four seconds may
    // have gone to a relay someone at the table cannot read, and the
    // only way to find out is to say it where they can hear.
    final insist = _repeatTick % 10 == 0;
    for (final e in List.of(_races.entries)) {
      final race = e.value;
      if (race.settled) continue;
      // A split race changes only when the jury comes, or the network
      // heals and evidence arrives on its own; repeating its evidence
      // every two seconds to peers who already have it is noise on a
      // shared relay. Every half minute is enough to say it is still
      // split.
      if (race.split && _repeatTick % 30 != 0) continue;
      if (race.action == null && race.boots.isEmpty && race.ends.isEmpty) continue; // nothing to say yet
      // And the rest widen as they go ([_Race.nextRepeatTick]).
      if (_repeatTick < race.nextRepeatTick) continue;
      // What this peer has to say again: its own, always; anybody
      // else's once the turn has been open long enough for carrying
      // to be the point ([_carryDue]).
      final carry = !ownOnly && _carryDue(e.key);
      final action = race.action;
      final sayAction = action != null && (carry || action.author == signer.publicKey || _speaksFor(e.key));
      final sayBoots = [
        for (final b in race.boots)
          if (carry || b.author == signer.publicKey) b,
      ];
      final sayEnds = [
        for (final c in race.ends)
          if (carry || c.author == signer.publicKey) c,
      ];
      if (!sayAction && sayBoots.isEmpty && sayEnds.isEmpty) continue;
      race.nextRepeatTick = _repeatTick + _repeatGap(race.repeats);
      race.repeats++;
      final everywhere = race.repeats == 2 || insist;
      if (sayAction) transport.broadcast(action.toJson(), everywhere: everywhere);
      for (final b in [...sayBoots, ...sayEnds]) {
        transport.broadcast(b.toJson(), everywhere: everywhere);
      }
    }
    for (final e in _myWitnessEvents.entries) {
      if (_races[e.key]?.settled == false) transport.broadcast(e.value.toJson(), everywhere: insist);
    }
    for (final p in _proposals.values) {
      if (!p.settled && p.action!.author == signer.publicKey) transport.broadcast(p.action!.toJson(), everywhere: insist);
    }
    for (final e in _myJuryWitnessEvents.entries) {
      if (_proposals[e.key]?.settled == false) transport.broadcast(e.value.toJson(), everywhere: insist);
    }
  }

  /// Whether this side is the voice of [turn]'s seat: a held seat the
  /// record has given to the escrow, and this side the custodian whose
  /// place it is to say the seat's moves ([_firstToSay]). What the
  /// seat's turn holds is this side's to say again, then, as the seat's
  /// own juror's was: the escrow keeps a move said at its turn, since a
  /// juror of the hand's is good after it ([_carryEscrow]), and one the
  /// seat's juror said before it went can have reached the jury and
  /// nobody at the table. Nobody else would say it again: a juror says
  /// only its own moves again, and this one, holding a move already,
  /// makes none of its own ([_takeUpSeat]).
  bool _speaksFor(TurnId turn) {
    final seat = _turnSeat[turn];
    return seat != null && _isEscrowed(turn.hand, seat) && _firstToSay(turn.hand, seat);
  }

  /// This peer's own unsettled witnesses, kept to repeat.
  final Map<TurnId, TableEvent> _myWitnessEvents = {};

  // ---- the jury -----------------------------------------------------------
  //
  // Every hand seats a jury drawn from whoever is online, to break a
  // deadlock the players cannot (docs/04-live-play.md). Here: the lowest key among
  // the participants heard lately proposes the draw over a snapshot of
  // who is online; the others witness it when the draw is what the
  // snapshot gives and the jurors are people they too have seen; a
  // majority carries it, beside the record, and everyone summons the
  // jurors. A split turn is appealed to them every ten seconds. A
  // juror follows the table like any peer behind, and rules only when
  // nobody who can still vote, as far as it can hear, could carry
  // either side — then by the seat's presence to it: heard and acted,
  // the action; silent, the removal. A verdict carries the winning
  // event, so it settles the same turn the same way wherever it lands.
  // A jury gone quiet is redrawn; nobody to draw from is said.

  /// The juries in force at [hand]: those carried for it — or, until
  /// one is, those of the latest hand before it that has any. A juror
  /// serves until relieved: a table of two with one gone quiet cannot
  /// carry a new jury, and that is exactly when it needs the old one.
  Iterable<Decision> _juriesFor(int hand) {
    var latest = -1;
    for (final d in juries) {
      if (d.event.hand <= hand && d.event.hand > latest) latest = d.event.hand;
    }
    return latest < 0 ? const [] : juries.where((d) => d.event.hand == latest);
  }

  /// The jurors of [hand]: everyone the events that drew a jury for
  /// it name, across every jury in force at it, and the list this
  /// side was summoned with where that event has not been carried
  /// here yet.
  ///
  /// The summons matters to the one it is addressed to and to nobody
  /// else, which is the only side that reads it here. A juror told it
  /// holds a seat ([botHolders]) has to find itself allowed to act for
  /// that seat ([_mayAct]) or it will make the seat's keys, refuse its
  /// own event, and make them again every second for ever. Every other
  /// peer goes on checking it against the event, which is the
  /// authority, so a summons that lied would buy nothing.
  Set<PublicKey> _jurorsOf(int hand) => {
        for (final d in _juriesFor(hand)) ...d.event.jurors,
        ...?_serving[hand],
      };

  /// The order this client answers appeals in at [hand]: the jury it
  /// was summoned into most recently by then, or the one in force.
  List<PublicKey> _orderFor(int hand) {
    var latest = -1;
    for (final h in _serving.keys) {
      if (h <= hand && h > latest) latest = h;
    }
    if (latest >= 0) return _serving[latest]!;
    final inForce = _juriesFor(hand);
    return inForce.isEmpty ? const [] : inForce.first.event.jurors;
  }

  /// Jurors in force at [hand] heard from lately, or drawn too recently
  /// to have been: within the table's [TableTiming.jurorSilenceMs],
  /// half a minute as standard, or [withinMs].
  Set<PublicKey> _liveJurors(int hand, {int? withinMs}) {
    final within = withinMs ?? timing.jurorSilenceMs;
    final live = <PublicKey>{};
    // This side is live to itself while it serves the hand. Heard-from
    // is how a juror knows about the others, and a client never hears
    // its own heartbeats — so a serving juror left out of here would
    // read as quiet to itself, and hand the seat it is holding back to
    // the escrow half a minute into every hand.
    if (_serving.containsKey(hand)) live.add(signer.publicKey);
    void consider(Iterable<PublicKey> jurors, int drawn) {
      for (final j in jurors) {
        if (live.contains(j)) continue;
        final heard = _jurorHeard[j];
        if ((heard != null && clock.nowMs - heard < within) || clock.nowMs - drawn < within) live.add(j);
      }
    }

    for (final d in _juriesFor(hand)) {
      consider(d.event.jurors, _juryAt[d.event.id] ?? 0);
    }
    // And the jury as the summons gave it, where the event that drew
    // it has not been carried here yet. [botHolders] reads the seats
    // from that same list, and the two have to agree about who is
    // about: a juror named there and missing here is one this side
    // would judge quiet and give a seat up for, its own included.
    final summoned = _serving[hand];
    if (summoned != null) consider(summoned, _servingSince[hand] ?? 0);
    return live;
  }

  /// The jury of the current hand as a view shows it: how many were
  /// drawn, how many are heard.
  ({int drawn, int live}) get jury => (drawn: _jurorsOf(game.handNumber).length, live: _liveJurors(game.handNumber).length);

  bool _recentWithin(PublicKey key, int ms) => clock.nowMs - (_lastHeard[key] ?? clock.nowMs) < ms;

  /// Proposes a jury for this hand when it is this peer's place to —
  /// the lowest key among the participants heard lately — and the hand
  /// has no jury of its own yet, or fewer than two of its jurors are
  /// heard from. Every ten seconds while it is needed, then every half
  /// minute: a proposal at a table that cannot carry one is not free.
  void _proposeJury() {
    final p = presence;
    if (p == null || !amSeated || _left || done) return;
    final hand = game.handNumber;
    final leaders = participants.where((k) => k == signer.publicKey || _recentWithin(k, 10000)).toList()..sort();
    if (leaders.first != signer.publicKey) return;
    if (_proposedForHand != hand) {
      _proposedForHand = hand;
      _proposalsThisHand = 0;
    }
    if (clock.nowMs - _lastProposedAt < (_proposalsThisHand < 3 ? 10000 : 30000)) return;
    final own = juries.any((d) => d.event.hand == hand);
    // Up to strength, not merely alive: a jury that only shrinks runs
    // out (docs/04-live-play.md). Whoever is drawn now is given a share
    // of every bot seat by the ones who hold them ([_topUpJury]). The guard below
    // still stops a redraw that would seat nobody new, so a room with
    // nobody spare proposes nothing.
    if (own && _liveJurors(hand).length >= jurySize) return;
    // Nor one this table has had to take a seat off for not playing
    // it ([_letGo]): heard from is not the same as playing, and drawn
    // again it would hold a seat again and cost the table the hand.
    final quiet = _jurorsOf(hand).difference(_liveJurors(hand)).union(_letGo);
    final here = p.online(withinMs: 15000).where((k) => !_ofThisTable(k)).toSet().difference(quiet);
    // What this table needs a jury for. Escrow needs somebody; bot
    // seats need enough jurors that a seat survives its holder going
    // (jury.dart, [juryToHoldBots]), and short of that the hand is not
    // dealt ([_startDealWhenReady]): it waits, and calls.
    final wanted = spec.sealed && _hasBotSeats ? juryToHoldBots : 1;
    // Drawn from the settled ones where there are enough of them.
    // What a hand's escrow rests on is the jurors it draws still
    // being there when a bot seat has to be opened, and the size of
    // the jury is a poor lever on that where the draw is a good one
    // (docs/04-live-play.md): somebody mid-game has a
    // reason to still be here in a minute, somebody glancing at the
    // lobby has none.
    //
    // A proposer may narrow its own candidates as it likes, because
    // what the table checks of a proposal is that each juror is
    // somebody *it* has seen lately, over a far wider window
    // ([_acceptableJury]). So this needs no agreement and cannot
    // deadlock — and where the settled are too few, the draw is from
    // everyone, since a jury of whoever is there beats none.
    final steady = p.settled(withinMs: 15000, forMs: jurySettledMs).where((k) => !_ofThisTable(k)).toSet().difference(quiet);
    final candidates = steady.length >= wanted ? steady : here;
    if (candidates.length < wanted) {
      if (clock.nowMs - _lastCalledAt >= 10000) {
        _lastCalledAt = clock.nowMs;
        p.callForJuror(spec.id);
      }
      if (candidates.isEmpty) {
        if (!needsJuror) _trace('nobody online to draw a jury from');
        needsJuror = true;
        return;
      }
      // Somebody is there, whatever they add up to.
      needsJuror = false;
      // Somebody, but not enough to hold the bot seats. A hand has one
      // jury and the assignment comes from it, so a second draw later
      // does not move the seats — which makes it worth holding the
      // first draw back until the called-for jurors arrive, rather than
      // drawing a jury now that can hold nothing. For as long as that
      // takes: the deal waits for a jury that holds every bot seat
      // ([_startDealWhenReady]).
      if (!own) {
        if (!_shortOfJurors) {
          _shortOfJurors = true;
          _trace('${candidates.length} online to draw from, $wanted wanted to hold the bot seats; called');
          _notify();
        }
        return;
      }
    }
    needsJuror = false;
    // A jury already drawn is kept unless a redraw would seat someone
    // new: with one stranger online the jury is that one, and
    // proposing it again every ten seconds carries nothing.
    if (own && _liveJurors(hand).isNotEmpty && candidates.every(_jurorsOf(hand).contains)) return;
    _lastProposedAt = clock.nowMs;
    _proposalsThisHand++;
    final snapshot = candidates.toList()..sort();
    final at = _positionOf(mySeat!);
    _emit(EventKind.jury, {
      'hand': hand,
      'turn': at.index,
      'seat': mySeat,
      'jurors': drawJury(spec.seed, hand, snapshot),
      'snapshot': snapshot,
    });
  }

  void _onJury(TableEvent event) {
    // A jury proposed is a set of keys a deal step may seal its escrow
    // to ([_validDeal]), so a deal step held back for want of them is
    // worth looking at again the moment they arrive.
    final before = _everProposed.length;
    _everProposed.addAll(event.jurors);
    if (_everProposed.length != before) _drainFuture();
    if (event.hand > game.handNumber) return _defer(event);
    if (event.hand < game.handNumber || !_isParticipant(event.author)) return;
    final race = _proposals.putIfAbsent(event.id, () => _Race()..action = event);
    race.forAction.add(event.author);
    race.forAction.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    if (amSeated && !_left && event.author != signer.publicKey && _acceptableJury(event)) _witnessJury(event);
    _settleJury(event.id);
  }

  void _reconsiderJury(TableEvent event) {
    final race = _proposals[event.id];
    if (race == null) return;
    if (!amSeated || _left || event.author == signer.publicKey) return;
    // Backed already, and said again: the proposer has not heard this
    // side back it. A proposal is said again only until it carries, a
    // witness is said once, and the second copy of a proposal is the
    // same event as the first — so a witness lost on its way to the
    // proposer would never be replaced, and the proposer would wait for
    // a jury the rest of the table is dealing under. Asked again,
    // answered again, as a turn sent again is ([_catchUp]).
    final mine = _myJuryWitnessEvents[event.id];
    if (mine != null) return transport.broadcast(mine.toJson());
    if (race.settled || !_acceptableJury(event)) return;
    _witnessJury(event);
    _settleJury(event.id);
  }

  /// Whether to back a proposal: the draw is what the snapshot gives,
  /// the snapshot holds nobody at this table — no device of an account
  /// seated here, as far as this peer's presence knows whose each key
  /// is — every juror is someone this peer has seen online too, and
  /// this peer is not already behind another live proposal for the hand.
  bool _acceptableJury(TableEvent e) {
    final snapshot = e.snapshot;
    final jurors = e.jurors;
    if (jurors.isEmpty || snapshot.any(_ofThisTable)) return false;
    final drawn = drawJury(spec.seed, e.hand, snapshot);
    if (drawn.length != jurors.length || !Iterable.generate(jurors.length).every((i) => drawn[i] == jurors[i])) return false;
    final p = presence;
    if (p != null) {
      final seen = p.online(withinMs: 300000);
      if (!jurors.every(seen.contains)) return false;
    }
    final backed = _myJuryWitness[e.hand];
    if (backed != null && backed != e.id) {
      final earlier = _proposals[backed];
      if (earlier != null && !earlier.settled && _recentWithin(earlier.action!.author, 10000)) return false;
      // Up to strength, not merely alive — the acceptance side of the
      // same rule the proposer uses. A peer that has backed a jury
      // does not keep backing new ones while that jury is whole, but
      // a jury below strength is one to top up: whoever is drawn now
      // is given a share of every bot seat by the ones who hold them
      // (docs/04-live-play.md).
      if (earlier != null && earlier.settled && _liveJurors(e.hand).length >= jurySize) return false;
    }
    return true;
  }

  void _witnessJury(TableEvent of) {
    _myJuryWitness[of.hand] = of.id;
    final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
      'event': of.id,
      'hand': of.hand,
      'turn': of.turn.index,
      'seat': of.seat,
      'jury': true,
    });
    transport.broadcast(w.toJson());
    _myJuryWitnessEvents[of.id] = w;
    _accept(w);
  }

  void _settleJury(String id) {
    final race = _proposals[id]!;
    if (race.settled) return;
    final e = race.action!;
    final of = _participantsAt(e.turn);
    if (race.forAction.intersection(of).length < _majority(of)) return;
    race.settled = true;
    juries.add(Decision(turn: e.turn, event: e, witnesses: Set.of(race.forAction), among: of, jury: true));
    _juryAt[e.id] = clock.nowMs;
    needsJuror = false;
    _reachOut();
    _refixHolders(e.hand);
    _checkSealed(e.hand);
    // And whatever was held back for it: keys name the draw they were
    // sealed to, and are taken only against a draw carried here
    // ([_keysNameTheDraw]).
    _drainFuture();
    // A draw the record has named to grow the escrow, carried here
    // after the play that named it, and holding up those after it.
    _applyGrowth(e.hand);
    _trace('jury for hand ${e.hand}: ${e.jurors.map((k) => k.substring(0, 4))} by ${race.forAction.length}');
    final p = presence;
    if (p != null && amSeated) {
      final draws = [
        for (final d in _juriesDrawnFor(e.hand)) ...[
          d.event.toJson(),
          for (final w in _proposals[d.event.id]?.witnessEvents ?? const <TableEvent>[]) w.toJson(),
        ],
      ];
      for (final j in e.jurors) {
        p.summon(j, {
          'table': spec.toJson(),
          'hand': e.hand,
          'jurors': e.jurors,
          'jury': e.id,
          // Whether this is the hand's first jury, which is the one a
          // bot seat's holder is read from. A juror summoned into a
          // redraw is told the jury as it stands now; acting on that
          // list would name a different holder for every bot seat.
          'first': _juriesDrawnFor(e.hand).first.event.id == e.id,
          // And every draw of the hand so far, as carried here
          // ([serveFor]).
          'draws': draws,
        });
      }
    }
    // A deal waiting on a jury to hold its bot seats can be built now.
    _startDealWhenReady();
    _notify();
  }

  /// Once a second at a seat: propose when it is this peer's place to,
  /// and appeal every stuck turn to the jury, every ten seconds. Stuck
  /// is a race that split, or any open turn while the table is paused
  /// — a table of two with one gone quiet claims nothing, by design,
  /// and has nothing to split; it asks.
  void _juryTick() {
    _proposeJury();
    _startDealWhenReady();
    for (final e in List.of(_races.entries)) {
      final race = e.value;
      if (race.settled || !(race.split || _pause != null)) continue;
      if (_jurorsOf(e.key.hand).isEmpty) continue;
      final last = _lastAppealAt[e.key];
      if (last != null && clock.nowMs - last < 10000) continue;
      _lastAppealAt[e.key] = clock.nowMs;
      _emit(EventKind.appeal, {'hand': e.key.hand, 'turn': e.key.index, 'seat': _turnSeat[e.key]}, everywhere: true);
    }
  }

  // ---- as a juror ----

  /// Summoned into the jury of [hand] at this table, [jurors] being
  /// the draw, foreman first. The client follows the table from then
  /// on and answers appeals in its place in the order.
  void serveFor(int hand, List<PublicKey> jurors,
      {String? juryId, bool first = false, List<Map<String, Object?>> draws = const []}) {
    if (mySeat != null) return;
    _serving[hand] = jurors;
    _servingSince.putIfAbsent(hand, () => clock.nowMs);
    _summonedFrom ??= hand;
    // A summons into the hand's *first* jury is the draw a bot seat's
    // holder is read from, arriving by the shorter road: kept apart
    // from the rest so that a redraw, which names the jury as it
    // stands now, never moves a seat ([botHolders]).
    if (first && juryId != null) _firstSummons.putIfAbsent(hand, () => (juryId: juryId, jurors: jurors));
    // And the hand's draws, each with the witnesses that carried it,
    // taken as a carry would give them. A seat's keys name the draw
    // they were sealed to and are taken only once it has carried here
    // ([_keysNameTheDraw]), and a juror summoned into a redraw needs
    // the draws before it. By carry alone they can come up to
    // [carryRepeatMs] late: every carry sends every jury, so one has
    // nearly always just been said, to the sides already there, a
    // moment before the newcomer was. Only proposals and their
    // witnesses, each checked as any event is.
    for (final json in draws) {
      final e = TableEvent.parse(json);
      if (e == null || e.table != spec.id || (e.kind != EventKind.jury && e.kind != EventKind.witness)) continue;
      _accept(e);
    }
    _notify();
  }

  /// Whether [hand] is history to this side: it serves as a juror, and
  /// the hand was over before the first summons that brought it here.
  ///
  /// A juror's client is let go of once the table has moved past every
  /// hand it serves, and a later summons starts a new one, which reads
  /// the record from the first hand. The key is the same, so the record
  /// names it as the holder of every bot seat its earlier client held;
  /// the secrets are not, and never were. Acting on that name, a juror
  /// drawn again would make fresh keys for a seat its earlier client
  /// held, take them over the ones on the record — a session keeps its
  /// own seat's keys and no other — and could verify nothing the table
  /// shuffled from them.
  ///
  /// So an earlier hand is one where this side holds nothing and makes
  /// no move for any seat: it follows the record there as a player
  /// does, and says nothing about it ([_emit]). A summons to an earlier
  /// hand arriving after the first does not move the line back. The
  /// table was past that hand when it drew the jury that brought this
  /// client, and the key may have served it in a client before this
  /// one, heard of from the jury rather than the summons.
  bool _beforeSummons(int hand) {
    final from = _summonedFrom;
    return mySeat == null && from != null && hand < from;
  }

  /// The first jury of each hand as a summons gave it, where one has
  /// said so. The event carries the same list and is the authority;
  /// this is the same thing arriving sooner, and a juror needs it
  /// sooner: one that does not know it holds a seat cannot make that
  /// seat's keys, and the hand stops at them.
  final Map<int, ({String juryId, List<PublicKey> jurors})> _firstSummons = {};

  /// When this side was first summoned to each hand: a summons is the
  /// jury arriving by another road, and a juror named in it is live
  /// from then as one named in a jury event would be ([_liveJurors]).
  final Map<int, int> _servingSince = {};

  /// Whether this client is still a juror of the hand in play or one
  /// to come; false once the table has moved past every hand it served,
  /// the game is over or has ended ([_onEndedClaim]), or nobody at the table
  /// has been heard for five minutes — a table everyone walked away
  /// from is nobody's to serve.
  bool get serving =>
      mySeat == null &&
      !done &&
      _failure == null &&
      (_serving.keys.any((h) => h >= game.handNumber) || _jurorsOf(game.handNumber).contains(signer.publicKey)) &&
      participants.any((k) => clock.nowMs - (_lastHeard[k] ?? 0) < 5 * 60 * 1000);

  /// A juror that stops: no more heartbeats, no more verdicts. The
  /// table notices the silence and draws another.
  void stopServing() {
    _serving.clear();
    _appealSeenAt.clear();
    _appealHeardAt.clear();
  }

  void _onAppeal(TableEvent event) {
    if (mySeat != null && event.seat == mySeat && event.author != signer.publicKey) _insist(event.turn);
    if (mySeat != null || !_isParticipant(event.author)) return;
    if (!_orderFor(event.hand).contains(signer.publicKey)) return;
    _appealSeenAt.putIfAbsent(event.turn, () => clock.nowMs);
    _appealHeardAt[event.turn] = clock.nowMs;
    _carryingHand = event.hand;
    _judgeAppeals();
  }

  /// How long an appeal stands once last heard: three of the people's,
  /// said every ten seconds while a turn is stuck ([_juryTick]). A
  /// juror rules by the seat's presence to it, and a juror that has
  /// lost the table hears every seat fall silent and cannot tell that
  /// from its own silence. Ruling on an appeal heard minutes before, it
  /// put the seat out on its own record alone, at a turn the table had
  /// settled by the seat's own card (`test/juror_cut_off_test.dart`).
  /// So it carries and rules only while it still hears the appeal; it
  /// takes it up again as soon as it does.
  static const appealStandsMs = 30000;

  final Map<TurnId, int> _relayedAt = {};

  void _judgeAppeals() {
    for (final turn in List.of(_appealSeenAt.keys)) {
      final race = _races[turn];
      if (race == null) continue; // still catching up to it
      if (race.settled) {
        _appealSeenAt.remove(turn);
        _appealHeardAt.remove(turn);
        _relayedAt.remove(turn);
        continue;
      }
      if (clock.nowMs - (_appealHeardAt[turn] ?? _never) >= appealStandsMs) continue;
      // What this juror holds for the turn, said again every five
      // seconds while the appeal stands: a table cut in two has its
      // votes on both sides, and the juror is the one who hears both.
      final last = _relayedAt[turn];
      if (last == null || clock.nowMs - last >= 5000) {
        _relayedAt[turn] = clock.nowMs;
        // By every path: the two sides of a cut table may read
        // different relays, and the juror is here to be heard by both.
        if (race.action != null) transport.broadcast(race.action!.toJson(), everywhere: true);
        for (final b in race.boots) {
          transport.broadcast(b.toJson(), everywhere: true);
        }
        for (final w in race.witnessEvents) {
          transport.broadcast(w.toJson(), everywhere: true);
        }
      }
      _judge(turn, race);
    }
  }

  /// The rule. A juror rules only when nobody who can still vote, as
  /// far as it can hear, could carry either side — votes that may yet
  /// come are carried, not overruled — and then by the seat's presence
  /// to it: heard and acted, the action stands; silent, the removal.
  /// Heard and not yet acted is nobody's to decide; the seat's own
  /// clock runs. The foreman rules first; each juror behind waits five
  /// seconds more.
  void _judge(TurnId turn, _Race race) {
    final order = _orderFor(turn.hand);
    final place = order.indexOf(signer.publicKey);
    if (place < 0 || clock.nowMs - _appealSeenAt[turn]! < place * 5000) return;
    final last = _verdictAt[turn];
    if (last != null && clock.nowMs - last < 10000) return;
    final seat = _turnSeat[turn]!;
    final holder = holders[seat];
    if (holder is! HumanSeat && (race.boots.isNotEmpty || race.rivals.isEmpty)) {
      // A held seat's juror's move against the escrow, neither able to
      // carry — or its move alone, short of a majority because the only
      // other person at the table has gone silent: ruled as a person's
      // seat is, by the juror's presence to this one — heard and moved,
      // the move stands; silent, or out of time on the turn by this
      // juror's clock, the escrow. Heard and not yet out of time is
      // nobody's to decide, and with no escrow said there is no other
      // side to rule for.
      final of = _participantsAt(turn);
      final needed = _majority(of);
      final forAction = race.forAction.intersection(of);
      final forRemoval = race.forRemoval.intersection(of);
      final awake = of.difference(forAction).difference(forRemoval).difference(race.forEnd).where((k) => !_silent(k)).length;
      if (forAction.length + awake >= needed || forRemoval.length + awake >= needed) return;
      final held = botHolders(turn.hand)[seat];
      final heard = held != null && _liveJurors(turn.hand).contains(held);
      final TableEvent winner;
      final String side;
      if (heard && race.action != null) {
        winner = race.action!;
        side = 'action';
      } else if (race.boots.isNotEmpty && (!heard || _outOfTime(seat))) {
        winner = race.boots.first;
        side = 'removal';
      } else {
        return;
      }
      _verdictAt[turn] = clock.nowMs;
      _emit(EventKind.verdict, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'side': side, 'event': winner.toJson()},
          everywhere: true);
      return;
    }
    if (holder is! HumanSeat) {
      // A bot seat said two ways, neither able to carry. Either will
      // do — the same card, by two voices the seat may have — so the
      // rule is one every juror reaches alone: the lowest id. Nobody is
      // removed from a bot seat, so there is no other side.
      final a = race.action;
      if (a == null || race.rivals.isEmpty || !_rivalsDeadlocked(race, _participantsAt(turn))) return;
      final winner = [a, ...race.rivals.values].reduce((x, y) => x.id.compareTo(y.id) <= 0 ? x : y);
      _verdictAt[turn] = clock.nowMs;
      _emit(EventKind.verdict, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'side': 'action', 'event': winner.toJson()},
          everywhere: true);
      return;
    }
    final of = _participantsAt(turn);
    final needed = _majority(of);
    final forAction = race.forAction.intersection(of);
    final forRemoval = race.forRemoval.intersection(of);
    // Whoever has backed this person's leave has given their voice on
    // the seat's way out, and will back neither its move nor its boot
    // ([_mayBackBoot]); and a person whose own leave is heard here is
    // not coming back to move, however long their device goes on
    // being heard.
    final leaving = _leaveBackers[holder.key] ?? const <PublicKey>{};
    final left = _leaves.values.any((c) => c.event.author == holder.key);
    final awake = of
        .difference(forAction)
        .difference(forRemoval)
        .difference(race.forEnd)
        .difference(leaving)
        .where((k) => !_silent(k) && !(left && k == holder.key))
        .toSet();
    final actionPossible = forAction.length + awake.length >= needed;
    final removalPossible = forRemoval.length + awake.difference({holder.key}).length >= needed;
    final said = _waitSaidAt[turn];
    if (said == null || clock.nowMs - said >= 10000) {
      _waitSaidAt[turn] = clock.nowMs;
      _trace('appeal at $turn: ${forAction.length} for, ${forRemoval.length} against, of ${of.length}; '
          'awake ${awake.map((k) => '${k.substring(0, 4)} ${clock.nowMs - (_lastHeard[k] ?? clock.nowMs)} ms ago')}; '
          'action ${race.action != null}; seat ${_silent(holder.key) ? 'silent' : 'heard'}');
    }
    if (actionPossible || removalPossible) return;
    TableEvent winner;
    String side;
    if (!_silent(holder.key) && !left) {
      if (race.action == null) return;
      winner = race.action!;
      side = 'action';
    } else {
      winner = race.boots.isNotEmpty
          ? race.boots.first
          : TableEvent.sign(signer, table: spec.id, kind: EventKind.absent, body: {
              'hand': turn.hand,
              'turn': turn.index,
              'seat': seat,
            });
      side = 'removal';
    }
    _verdictAt[turn] = clock.nowMs;
    _emit(EventKind.verdict, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'side': side, 'event': winner.toJson()}, everywhere: true);
  }

  /// A verdict, by a juror of the hand as this peer knows the jury,
  /// about a turn open here: the side it names wins, with the event it
  /// carries.
  ///
  /// One about a turn still to come here is kept for that turn, before
  /// asking whose it is: a peer carried forward is sent every removal
  /// in the record with its verdict, wherever it is ([_catchUp]), and
  /// one far behind — a juror summoned late, reading from the first
  /// hand — hears a removal's verdict long before the jury of its hand.
  /// Asked then, the juror would be nobody it knows, and the verdict
  /// dropped once is never read again: every copy after it is a repeat.
  /// The peer would stop at that removal for good, still counting the
  /// seat a person's, and read every later hand's bot seats a seat
  /// short of everyone else (docs/04-live-play.md, "Appeals and
  /// verdicts").
  void _onVerdict(TableEvent event) {
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (!_jurorsOf(turn.hand).contains(event.author) && !_orderFor(turn.hand).contains(event.author)) {
      // And one by a juror not yet known here, at a turn this peer has
      // reached, is not taken as seen: the draw that brought the juror
      // in may still be on its way, and a copy after it is read afresh.
      _seen.remove(event.id);
      return;
    }
    final race = _races[turn];
    if (where < 0 || (race?.settled ?? false)) {
      // The escrow ruled for at a turn settled here by the seat's move
      // first ([_lateEscrowAt]).
      final ruled = event.ruled;
      if (event.side == 'removal' &&
          _lateEscrowAt(turn) &&
          ruled != null &&
          ruled.kind == EventKind.escrow &&
          ruled.table == spec.id &&
          ruled.turn == turn &&
          ruled.seat == _turnSeat[turn] &&
          event.seat == ruled.seat &&
          _participantsAt(turn).contains(ruled.author)) {
        if (!race!.boots.any((b) => b.id == ruled.id)) race.boots.add(ruled);
        _seen.add(ruled.id);
        _settleLateEscrow(turn, verdict: event);
      }
      return _catchUp(turn);
    }
    if (race == null) return _defer(event);
    final seat = _turnSeat[turn]!;
    if (event.seat != seat) return;
    final holder = holders[seat];
    final ruled = event.ruled;
    if (ruled == null || ruled.table != spec.id || ruled.seat != seat || ruled.turn != turn) return;
    final of = _participantsAt(turn);
    if (holder is! HumanSeat) {
      if (event.side == 'removal') {
        // The escrow, ruled for: a claim by a person at the table.
        if (ruled.kind != EventKind.escrow || !_isParticipant(ruled.author)) return;
        if (botHolders(turn.hand)[seat] == null || _isEscrowed(turn.hand, seat)) return;
        if (!race.boots.any((b) => b.id == ruled.id)) {
          race.boots.add(ruled);
          _seen.add(ruled.id);
        }
        race.forRemoval.add(ruled.author);
        _trace('verdict at $turn by ${event.author.substring(0, 4)}: bot seat $seat goes to the escrow');
        return _carryEscrow(turn, race, ruled, of, verdict: event);
      }
      // A bot seat's move ruled for: against a claim for the escrow, or
      // against another move for the seat — by a voice the seat may
      // have, and a move this side can check. Whichever this side heard
      // first gives way, and its witnesses with it. A deal step or an
      // audit too: the people can split on one of those between the
      // juror's step and the escrow as on a card, and a ruling for the
      // step that nobody took would leave the turn open for good. Not
      // the audit of a seat already given to the escrow, which is its
      // pieces and nobody's move ([_isEscrowedAudit]).
      //
      // A deal step it rules for is kept, as the step itself is
      // ([_onAction]), where this side cannot take it yet: its juror a
      // stranger here for a moment, or its keys naming a draw the
      // record has not sealed the hand to here yet ([_checkSealed]).
      // Dropped, the verdict would be a repeat ever after, and a side
      // that needs it — a juror summoned late, the table split at the
      // seat — would wait at the turn for good.
      if (event.side != 'action') return;
      if (!_mayAct(seat, ruled.author, turn.hand)) {
        if (ruled.kind == EventKind.deal) _defer(event);
        return;
      }
      if (ruled.kind != EventKind.pass && ruled.kind != EventKind.play && ruled.kind != EventKind.deal) return;
      if (_isEscrowedAudit(turn, seat)) return;
      if (race.action?.id != ruled.id) {
        if (!_checkable(ruled)) return _defer(event, quietly: true);
        if (!_valid(ruled, seat)) {
          if (ruled.kind == EventKind.deal) _defer(event);
          return;
        }
        race.rivals.putIfAbsent(ruled.id, () => ruled);
        race.forRival.putIfAbsent(ruled.id, () => {ruled.author});
        race.adopt(ruled.id);
      }
      _seen.add(ruled.id);
      _trace('verdict at $turn by ${event.author.substring(0, 4)}: bot seat $seat\'s move by ${ruled.author.substring(0, 4)} stands');
      return _carryAction(turn, race, ruled, of, verdict: event);
    }
    if (event.side == 'action') {
      if (ruled.author != holder.key) return;
      if (ruled.kind != EventKind.pass && ruled.kind != EventKind.play && ruled.kind != EventKind.deal) return;
      if (!_checkable(ruled)) return _defer(event, quietly: true);
      // A person's deal step can be early here too ([_validDeal]).
      if (!_valid(ruled, seat)) {
        if (ruled.kind == EventKind.deal) _defer(event);
        return;
      }
      race.action = ruled;
      race.forAction.add(ruled.author);
      _seen.add(ruled.id);
      _trace('verdict at $turn by ${event.author.substring(0, 4)}: the action stands');
      _carryAction(turn, race, ruled, of, verdict: event);
    } else if (event.side == 'removal') {
      if (ruled.kind != EventKind.boot && ruled.kind != EventKind.absent) return;
      if (ruled.author == holder.key) return;
      if (!_isParticipant(ruled.author) && ruled.author != event.author) return;
      if (!race.boots.any((b) => b.id == ruled.id)) {
        race.boots.add(ruled);
        _seen.add(ruled.id);
      }
      if (_isParticipant(ruled.author)) race.forRemoval.add(ruled.author);
      _trace('verdict at $turn by ${event.author.substring(0, 4)}: seat $seat is out');
      _carryRemoval(turn, race, ruled, of, verdict: event);
    }
  }

  void _log(Decision d) {
    if (!d.removal && !d.jury) _onRecord.add(d.turn);
    var i = record.length;
    while (i > 0 && record[i - 1].compareTo(d) > 0) {
      i--;
    }
    record.insert(i, d);
  }

  void _notify() {
    if (_closed) return;
    _sendWanted();
    if (_notifying) {
      _notifyAgain = true;
      return;
    }
    _notifying = true;
    do {
      _notifyAgain = false;
      _changes.add(null);
    } while (_notifyAgain && !_closed);
    _notifying = false;
  }
}

/// A leave heard, and who backs it: the leaver first, its signature its
/// own vote ([TableClient._settleLeave]).
class _Leave {
  _Leave(this.event);
  final TableEvent event;
  final Set<PublicKey> backers = {};

  /// Every backing received, so the whole decision can be handed to a
  /// peer that missed some of it.
  final List<TableEvent> witnessEvents = [];
  bool carried = false;
}

class _Race {
  TableEvent? action;
  final List<TableEvent> boots = [];

  /// How many times this peer has said the race's evidence again, and
  /// the tick it may be said at next. A turn is repeated so that a
  /// peer who missed it gets it; a peer who has it wants none of them,
  /// and at a sealed table a repeated deal turn is twelve kilobytes of
  /// shuffle argument every time (service/tool/wire_over_socket.dart).
  /// So the gap widens: two seconds, four, eight, sixteen, then every
  /// half minute for as long as it stays open. What a seat really
  /// stuck needs is not the fifth repeat but the boot path, which says
  /// the action again where the booter can hear it.
  int repeats = 0;
  int nextRepeatTick = 0;

  /// Every witness received, so the whole decision can be handed to a
  /// peer that missed some of it.
  final List<TableEvent> witnessEvents = [];
  final Set<PublicKey> forAction = {};
  final Set<PublicKey> forRemoval = {};

  /// Claims that the game ends here, and who backs one: the third way a
  /// turn can go, where nobody left can move it ([TableClient._claimEnd]).
  /// A person's voice at a turn goes one way, so these are counted
  /// apart from the move and the removal, and a majority of them ends
  /// the game at the turn, on every record.
  final List<TableEvent> ends = [];
  final Set<PublicKey> forEnd = {};
  bool settled = false;
  bool split = false;

  /// At a bot seat, the moves said for it other than [action], by id,
  /// and who has witnessed each. A person's seat has one voice, and a
  /// second move from it is equivocation that the first outlasts; a bot
  /// seat can have two — its juror, and a custodian the table gave it
  /// to — each saying the same card for it, and the table has to end
  /// up on one of them.
  final Map<String, TableEvent> rivals = {};
  final Map<String, Set<PublicKey>> forRival = {};

  /// [action] and its witnesses swapped for the rival [id]'s.
  void adopt(String id) {
    final was = action;
    if (was != null) {
      rivals[was.id] = was;
      forRival[was.id] = Set.of(forAction);
    }
    action = rivals.remove(id);
    forAction
      ..clear()
      ..addAll(forRival.remove(id) ?? const {});
  }
}
