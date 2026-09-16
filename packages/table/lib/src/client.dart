/// One seat's view of a table, and the protocol that keeps four seats
/// agreeing without a server.
///
/// The engine is the referee: every client runs the same rules over the
/// same deal, so a play is accepted because everyone's copy of the rules
/// accepts it, not because anyone says so. What the protocol adds is
/// **when** a turn is settled. Every turn is a race between two pools of
/// signatures: the seat's own action (a pass or a play, signed by the
/// seat and witnessed by others), and the seat's removal (a boot pressed
/// after fifteen seconds, or an absence claimed after thirty of silence,
/// pressed or countersigned by others). Each participant signs one side
/// or the other, never both, and a side wins with a strict majority of
/// the participants. Then, and only then, the next turn opens, so there
/// is never anything to roll back. A signed Leave needs no majority: it
/// is evidence. When everyone has signed and neither side has a
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
/// turn opens and moves on (docs/04-live-play.md, "why there is no
/// service in any of this").
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
import 'model.dart';
import 'sealed_pass.dart';
import 'signing.dart';
import 'spec.dart';
import 'time_bank.dart';
import 'jury.dart';
import 'transport.dart';

/// Why a table is not moving.
/// How a modified client lies (docs/03-fair-deal.md), for the
/// simulator. These are the two faults at a sealed table that the
/// deal's own proofs cannot catch — a seat saying it holds the two of
/// clubs nowhere has nothing to prove, and a token sealed to one pair
/// of eyes is nothing anyone else can check. What the table does about
/// each is worth a test, and there is no testing it without committing
/// it.
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
  /// receiver will never open, and that nobody else can tell from an
  /// honest pass. Asked, it shows the three in the clear as an honest
  /// passer would, and the hand plays on — with three of the receiver's
  /// cards in the open, which is the most this fault can get and why it
  /// is not worth committing.
  seal,

  /// The same pass, and no answer. The table takes its seat at whatever
  /// turn of its own is open, and its hand opens from escrow, which
  /// opens the three anyway.
  sealNoAnswer,
}

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
  /// their keys match.
  /// What two records are compared by: the action's id, or for a
  /// removal the seat and the turn — "seat 2 is out as of h0/t38" is
  /// the decision, and peers may hold different evidence for it: one
  /// the boot pressed at fifteen seconds, another the boot made for
  /// silence, a third the seat's own leave.
  String get key => jury
      ? 'jury@$turn#${event.id.substring(0, 8)}'
      : removal
          ? 'out@$turn#${event.seat}'
          : event.id;

  /// Canonical position in a record. The concurrent turns — a deal
  /// round's, the pass, the audit — settle in a different order at
  /// every peer; ordering by position (TurnId.position), with
  /// departures ahead of the actions at the same position and those by
  /// seat, makes every peer's record the same list.
  int compareTo(Decision other) {
    if (turn.hand != other.turn.hand) return turn.hand.compareTo(other.turn.hand);
    final a = turn.position;
    final b = other.turn.position;
    if (a != b) return a.compareTo(b);
    if (removal != other.removal) return removal ? -1 : 1;
    return event.seat.compareTo(other.event.seat);
  }

  @override
  String toString() =>
      '$turn ${jury ? 'JURY' : removal ? 'OUT' : 'ok'} $event by ${witnesses.length}${verdict != null ? ' by verdict' : ''}';
}

class TableClient {
  TableClient({
    required this.spec,
    required this.signer,
    required this.transport,
    required this.clock,
    this.timeBank = TimeBank.standard,
    this.silenceAfterMs = 120000,
    this.heartbeatMs = 5000,
    this.presence,
    this.crypto,
    Random? random,
  })  : _random = random,
        game = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target),
        holders = List.of(spec.seats),
        _humans = {for (final h in spec.seats) if (h is HumanSeat) h.key} {
    if (spec.sealed && crypto == null) throw ArgumentError('a sealed table needs the deal\'s cryptography');
  }

  final TableSpec spec;
  final Signer signer;
  final Transport transport;
  final Clock clock;

  /// The clock every seat plays against: a grace per decision, a bank
  /// per hand, Boot once both are spent (time_bank.dart).
  final TimeBank timeBank;
  final int silenceAfterMs;
  final int heartbeatMs;

  /// Who is online, and how a juror is summoned; null at a table that
  /// draws no jury.
  final Presence? presence;

  /// The deal's primitives, at a sealed table.
  final DealCrypto? crypto;

  /// Where the deal's secrets and seeds come from: secure by default;
  /// the simulator seeds it, so a table replays.
  final Random? _random;

  final HeartsGame game;

  /// Who holds each seat now; humans become bots as they go.
  final List<SeatHolder> holders;

  /// Every human who sat down.
  final Set<PublicKey> _humans;

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

  /// Whether the Boot button shows for [seat]: a human's turn, open
  /// past its grace with the seat's bank spent, by this peer's clock.
  /// Whether this device knows its own events are not getting out —
  /// every relay refusing them (relays.dart). A peer in that state is
  /// the least qualified to say anyone else is absent: what looks like
  /// their silence may be this device's own deafness, and the claim
  /// would not reach the table anyway. So while it holds, this peer
  /// neither claims absence, nor countersigns a boot, nor offers one.
  bool writesRefused = false;

  bool canBoot(int seat) {
    if (!amSeated || seat == mySeat || holders[seat] is! HumanSeat) return false;
    if (!connectedToMajority || writesRefused) return false;
    if (_catchingUp((holders[seat] as HumanSeat).key)) return false;
    // A seat waiting on an answer it is owed is not idle: three of its
    // cards will not open and it cannot play what it cannot see
    // (docs/03-fair-deal.md). It waits the clock a device answers by,
    // and no longer — a table that waited for ever on a passer that
    // will not answer would be the worse hole of the two.
    if (_complaints.values.any((c) => c.to == seat && clock.nowMs - c.atMs < timeBank.fixedMs)) return false;
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
      return _removedAtTurn.contains(turn) ? TurnState.settledByRemoval : TurnState.settledByAction;
    }
    if (race.split) return TurnState.split;
    if (race.boots.isNotEmpty) return TurnState.contested;
    if (race.action != null) return TurnState.acting;
    return TurnState.open;
  }

  /// Every turn this peer has opened, with its state.
  Map<TurnId, TurnState> get turnStates => {for (final t in _races.keys) t: turnStateOf(t)!};

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
    for (final e in _races.entries) {
      if (e.value.settled) continue;
      final r = e.value;
      b.writeln('  open ${e.key} seat ${_turnSeat[e.key]}: action ${r.action?.kind.name} by '
          '${r.forAction.map((k) => k.substring(0, 4))} boots ${r.boots.length} by ${r.forRemoval.map((k) => k.substring(0, 4))} '
          'needed ${_majority(_participantsAt(e.key))} of ${_participantsAt(e.key).length}');
    }
    if (_future.isNotEmpty) {
      b.writeln('  deferred ${_future.length}: '
          '${_future.take(4).map((e) => '${e.kind.name}@${e.kind == EventKind.release ? 'h${e.hand}' : e.turn}')}');
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

  // As a juror: the hands this client serves, each with the jury it was
  // summoned into, foreman first; the appeals heard; the verdicts given.
  final Map<int, List<PublicKey>> _serving = {};
  final Map<TurnId, int> _appealSeenAt = {};
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
    _timers.add(clock.schedule(heartbeatMs, _heartbeat));
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
    final turn = TurnId.pass(game.handNumber, mySeat!);
    if (!_races.containsKey(turn) || _races[turn]!.settled) return;
    final body = <String, Object?>{'hand': game.handNumber, 'turn': turn.index, 'seat': mySeat};
    if (spec.sealed) {
      // The cards stay hidden: the positions move, and the tokens that
      // open them go to the receiver alone.
      final d = _deal!;
      final positions = [for (final c in cards) d.positionOf(mySeat!, c.index)];
      if (positions.any((p) => p == null)) return;
      final to = (mySeat! + game.passDirection.seatOffset) % seatCount;
      final m = d.passMessage(to, [for (final p in positions) p!]);
      if (m == null) return;
      if ((lies == Lie.seal || lies == Lie.sealNoAnswer) && m['sealed'] != null) {
        // Sealed to nothing anybody holds: the shape of a pass, and
        // three cards the receiver will never open (docs/03).
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
    final turn = TurnId.play(game.handNumber, _playIndex);
    final body = <String, Object?>{'hand': game.handNumber, 'turn': turn.index, 'seat': mySeat, 'card': card.code};
    if (spec.sealed) {
      final d = _deal!;
      final p = d.positionOf(mySeat!, card.index);
      if (p == null) return;
      final m = d.playToken(p);
      if (m == null) return;
      body.addAll(m);
    }
    _emit(EventKind.play, body);
  }

  /// The polite exit: signed, so nobody needs to agree. Made at this
  /// peer's current position, which is where it takes effect — unless
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
    _emit(EventKind.boot, {'hand': turn.hand, 'turn': turn.index, 'seat': seat}, everywhere: true);
  }

  /// Signs, sends and accepts one event of this peer's own.
  /// [everywhere] sends it by every path the transport has: the rare
  /// events that decide something for someone else — a boot, a claim
  /// of absence, an appeal, a verdict, a leave, a complaint and its
  /// answer — must reach a peer or a juror that cannot read the relay
  /// this device writes to.
  void _emit(EventKind kind, Map<String, Object?> body, {bool everywhere = false}) {
    final event = TableEvent.sign(signer, table: spec.id, kind: kind, body: body);
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

  void _openHand() {
    played.clear();
    step = 0;
    _proposeJury();
    if (spec.sealed) {
      _startDeal();
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
    if (botActs && holders[seat] is BotSeat) {
      _botTurn(turn, seat);
    }
  }

  /// A bot's turn, taken once the stack is clear of the turn before
  /// it. A bot's move closes its turn, which opens the next, which may
  /// be a bot's too: run as a loop, a table of bots plays a whole game
  /// — a deserted table, a leaver's client looking on — in one call
  /// without the stack growing by a frame per card, which in a browser
  /// was a stack overflow by hand two.
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
  bool _runningBots = false;

  /// A bot's turn: its move is a function of the deal and the record,
  /// computed here and settled at once. At a sealed table its deal
  /// steps are public work the session already did, and a departed
  /// person's seat cannot move until its secret is rebuilt from
  /// escrow — the turn stalls, settled or not, until the pieces come.
  void _botActs(TurnId turn, int seat) {
    final d = _deal;
    if (d != null) {
      if (d.awaitsSecret(seat)) return _stall(turn, seat);
      if (turn.isDeal || turn.isAudit) {
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
      if (d != null) d.playOpen(seat, d.positionOf(seat, card.index)!);
      game.play(seat, card);
      played.add(card);
    }
    _races[turn]!.settled = true;
    _closeTurn(turn);
  }

  /// After a turn settles: sweep, deal, and open what is next.
  void _closeTurn(TurnId turn) {
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
    // re-sent is a departed seat's last play — but a table where only
    // some peers hear a seat directly (one relay socket gone quiet,
    // one WebRTC channel of three) used to split at that seat's turn,
    // the deaf peers booting it while the others witnessed its play.
    // Not while this peer is itself behind and being carried forward:
    // then the work arriving is the table's past, however new to this
    // peer, and a juror that took a quiet seat's old plays for signs
    // of life restarted its silence clock on catching up.
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
        // not often. Carrying it forward like anyone else used to have
        // every peer at the table answering its every heartbeat with
        // the whole record, forever.
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
      if (event.kind != EventKind.leave &&
          event.kind != EventKind.release &&
          event.kind != EventKind.complain &&
          event.kind != EventKind.show) {
        _catchUp(event.turn);
      }
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
    // The events a hand carries beside its turns: a release of an
    // escrow piece, and a pass that will not open being said and
    // answered (docs/03-fair-deal.md). They are of the hand, not of a
    // moment in it.
    if (event.kind == EventKind.release || event.kind == EventKind.complain || event.kind == EventKind.show) {
      return event.hand < game.handNumber;
    }
    final t = event.turn;
    if (t.hand != game.handNumber) return t.hand < game.handNumber;
    return t.position < _herePosition;
  }

  void _onDisconnected(PublicKey key) {
    // A closed connection is silence the transport is sure of, so most
    // of the allowance is already spent.
    if (_humans.contains(key)) {
      _lastHeard[key] = clock.nowMs - silenceAfterMs + 3000;
    }
  }

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
      case EventKind.complain:
        _onComplain(event);
      case EventKind.show:
        _onShow(event);
      case EventKind.boot:
      case EventKind.absent:
        _onBoot(event);
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
    }
  }

  void _defer(TableEvent event) {
    _seen.remove(event.id);
    // Once each: a peer far behind is repeated at for minutes, and a
    // list that grew by every repeat was drained, and grown, at every
    // turn it closed.
    if (!_futureIds.add(event.id)) return;
    _future.add(event);
    if (event.kind != EventKind.witness && event.kind != EventKind.release) {
      final where = event.kind == EventKind.complain || event.kind == EventKind.show ? 'h${event.hand}' : '${event.turn}';
      _trace('defer ${event.kind.name}@$where from ${event.author.substring(0, 4)}');
    }
  }

  final Set<String> _futureIds = {};

  void _drainFuture() {
    if (_future.isEmpty) return;
    final again = List.of(_future);
    _future.clear();
    _futureIds.clear();
    for (final e in again) {
      _accept(e);
    }
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
    final live = participants.where((k) => k == signer.publicKey || _recent(k)).toList()..sort();
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
    if (settled.isEmpty) return;
    // Once a couple of seconds per turn, whoever is asking: a peer far
    // behind repeats a lot, and every answer is itself repeated evidence
    // to everyone else.
    final key = turns.first;
    final last = _lastCatchUp[key];
    if (last != null && clock.nowMs - last < 2000) return;
    // And a budget over all turns, in events: a peer far behind asks
    // about a window of them per heartbeat, and each answer is several
    // events. Unbudgeted, two peers carrying two others forward sent a
    // public relay forty events a second between them, which is how
    // relays come to ban you. Refilled at a few a second; what is not
    // sent now is asked for again on the next heartbeat.
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
    for (final t in settled) {
      _sendEvidence(t);
    }
    for (final d in record) {
      if (d.removal && !settled.contains(d.turn)) _sendEvidence(d.turn);
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

  /// One catch-up event, if the budget has it.
  void _send(Map<String, Object?> json) {
    _refillCatchUp();
    if (_catchUpTokens < 1) return;
    _catchUpTokens -= 1;
    transport.broadcast(json);
  }

  /// Catch-up events in hand, refilled at [catchUpPerSecond] up to
  /// [catchUpBurst].
  double _catchUpTokens = catchUpBurst.toDouble();
  int _catchUpRefilledAt = 0;
  // Raised from twelve and forty-eight for the sealed table, where a
  // juror summoned mid-hand has to be current before a departed
  // seat's hand can be opened with its piece: a hand is some eighty
  // turns of four or five events each, and at twelve a second that
  // was a minute and a half of everyone waiting.
  static const catchUpPerSecond = 24;
  static const catchUpBurst = 96;

  void _refillCatchUp() {
    final now = clock.nowMs;
    if (_catchUpRefilledAt == 0) _catchUpRefilledAt = now;
    _catchUpTokens = (_catchUpTokens + (now - _catchUpRefilledAt) * catchUpPerSecond / 1000).clamp(0, catchUpBurst).toDouble();
    _catchUpRefilledAt = now;
  }

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

  bool _jurorRecent(PublicKey j) => clock.nowMs - (_jurorHeard[j] ?? _never) < 30000;

  void _onAction(TableEvent event) {
    _relayIfAppealed(event);
    // An audit of the hand this peer is still in the middle of: the
    // table is opening the hand to give it up, and the seat that
    // cannot go on for want of an answer goes with it. It cannot see
    // the turn the table is waiting at — it never got past the pass —
    // so it does not call the hand itself (docs/03-fair-deal.md).
    if (event.kind == EventKind.deal && event.hand == game.handNumber && _waitingOnAPass && event.turn.isAudit) {
      _openTheHand('the table is opening this hand');
    }
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    final race = _races[turn];
    if (race == null) return _defer(event); // current, and not open yet
    if (race.settled) return _catchUp(turn);
    final seat = _turnSeat[turn]!;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != event.author) return;
    if (!_valid(event, seat)) {
      // Not valid here now — which for a deal step can mean this peer
      // has yet to see what it is checked against; let a re-send be
      // looked at afresh.
      _seen.remove(event.id);
      return;
    }
    if (race.action != null && race.action!.id != event.id) return; // equivocation: the first stands
    race.action = event;
    race.forAction.add(event.author);
    race.forAction.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    // Witness the action unless this peer already backed the boot — or
    // the seat owes an answer for a pass that will not open, in which
    // case no card of its carries until it gives one, and its own turn
    // is where the table takes its seat (docs/03-fair-deal.md). Its
    // steps of the deal still carry: the audit is the one thing a seat
    // in that position can do that the table wants.
    final held = turn.isPlay && _complaints.containsKey(seat);
    if (amSeated && event.author != signer.publicKey && !_myWitness.containsKey(turn) && !held) {
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
    } else {
      _considerCountersigning(turn, event);
    }
    _settle(turn);
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
  /// knowledge — the seat has been on turn fifteen seconds by this
  /// clock, or has not been heard from for thirty — and it holds no
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
    if (holder is! HumanSeat) return;
    // By this peer's own accounting of the seat's clock; the tick asks
    // again every second until it agrees.
    final agrees = _overdue(turn, seat) || _silent(holder.key);
    if (!agrees) return;
    _witness(turn, boot);
  }

  void _witness(TurnId turn, TableEvent of) {
    _myWitness[turn] = of.id;
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
    if (event.body['jury'] == true) {
      // For a proposal not seen yet: kept by its id, never deferred,
      // since its position is the proposer's, not a turn of this hand.
      _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
      _earlyWitnessEvents.putIfAbsent(id, () => []).add(event);
      return;
    }
    final race = _races[turn];
    if (race != null) {
      if (race.settled) return _catchUp(turn);
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
    final forAction = race.forAction.intersection(of);
    final forRemoval = race.forRemoval.intersection(of);
    if (forAction.length >= needed) {
      _carryAction(turn, race, race.action!, of);
    } else if (forRemoval.length >= needed) {
      _carryRemoval(turn, race, race.boots.first, of);
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
      if (holder is! HumanSeat) return;
      final gone = of.where((k) => k != signer.publicKey && _silent(k)).toSet();
      final actionReachable = of.difference(forRemoval).difference(gone.difference(forAction)).length >= needed;
      final removalReachable =
          of.difference(forAction).difference({holder.key}).difference(gone.difference(forRemoval)).length >= needed;
      if (!actionReachable && !removalReachable) {
        race.split = true;
        _pause = Pause.waitingForJury;
        _trace('split at $turn: ${forAction.length} for the action, ${forRemoval.length} against');
      }
    }
  }

  /// The seat's action wins the race for [turn]: by a majority, or by
  /// a juror's [verdict] where no majority could be had.
  void _carryAction(TurnId turn, _Race race, TableEvent e, Set<PublicKey> of, {TableEvent? verdict}) {
    race.settled = true;
    final seat = _turnSeat[turn]!;
    _spend(turn, seat);
    final d = _deal;
    if (e.kind == EventKind.deal) {
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
    _liftPause();
    _closeTurn(turn);
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
  }

  // ---- the deal -------------------------------------------------------------
  //
  // Doc 03: the cards of a sealed table come from a deal every seat
  // shuffles with a proof, and each person's cards are theirs alone to
  // see. Here the deal is turns like any other. At the hand's start
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

  void _startDeal() {
    final c = crypto!;
    _deal = DealSession(
      c,
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
      mySeat: amSeated ? mySeat : null,
      myKey: signer.publicKey,
      wrap: signer.sharedSecretWith,
      random: _random,
    );
    _dealsByHand[game.handNumber] = _deal!;
    _stalled.clear();
    _sentPass.clear();
    _complaints.clear();
    _complainedAt.clear();
    _showedAt = -10000;
    for (var s = 0; s < seatCount; s++) {
      _openTurn(TurnId.deal(game.handNumber, 0, s), s);
    }
    _bootLiars();
    _actOnDeal();
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
    _actOnDeal();
    _drainFuture();
  }

  /// Whether this hand is being opened rather than played
  /// ([_openTheHand]).
  bool _openingAudit = false;

  /// The deal is open and the hand is given up: nothing was passed and
  /// nothing was played, so nothing is scored, and the next hand is
  /// dealt in its place — the redeal doc 03 asks for, under a hand
  /// number of its own because that is where its turns live.
  ///
  /// Whoever was dealt the lead card and disclaimed it is marked here
  /// and removed at the first turn of theirs that opens ([_bootLiars]).
  /// It cannot be removed at the turn it lied at: that one settled
  /// long before the cards said so.
  void _giveUpHand() {
    final d = _deal;
    // Whoever the open hand shows to have broken it: the seat dealt the
    // lead card that said it held it nowhere, and the seat whose seal
    // would not open. Marked here and removed at the first turn of
    // theirs that opens ([_bootLiars]) — never at the turn they did it
    // at, which settled long before the cards said so.
    final blamed = <int>{
      if (d?.lied case final seat?) seat,
      ...?d?.sealedShut.values,
      ..._complaints.keys,
    };
    for (final seat in blamed) {
      final holder = holders[seat];
      if (holder is HumanSeat) _liars.add(holder.key);
    }
    _trace('hand ${game.handNumber} given up, opened${blamed.isEmpty ? '' : '; seat(s) $blamed broke it'}');
    _openingAudit = false;
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
    if (d == null || !amSeated || _left || done) return;
    final me = mySeat!;
    final h = game.handNumber;
    TurnId? open(TurnId t) {
      final r = _races[t];
      return r != null && !r.settled && r.action == null ? t : null;
    }

    final keys = open(TurnId.deal(h, 0, me));
    if (keys != null) {
      final jurors = _jurorsOf(h);
      final waited = clock.nowMs - _openedAt[keys]!;
      if (jurors.isNotEmpty || presence == null || needsJuror || waited >= 10000) {
        d.custodians = jurors.toList()..sort();
        _emitDeal(keys, 0, d.myKeys()!);
      }
    }
    final shuffle = open(TurnId.deal(h, 1, me));
    if (shuffle != null && d.nextShuffler == me) _emitDeal(shuffle, 1, d.myShuffle()!);
    final tokens = open(TurnId.deal(h, 2, me));
    if (tokens != null && d.deck != null) _emitDeal(tokens, 2, d.myTokens()!);
    final declare = open(TurnId.deal(h, 3, me));
    if (declare != null) {
      final m = d.myDeclaration();
      if (m != null) _emitDeal(declare, 3, lies == null ? m : {'seat': m['seat'], 'position': -1});
    }
    final audit = open(TurnId.audit(h, me));
    if (audit != null && (game.phase == Phase.handOver || game.phase == Phase.gameOver || _openingAudit)) {
      _emitDeal(audit, 4, d.myAudit()!);
    }
  }

  /// How this client lies about the lead card, or null — which is every
  /// client but a simulated one. See [Lie].
  Lie? lies;

  void _emitDeal(TurnId turn, int round, Map<String, Object?> m) =>
      _emit(EventKind.deal, {'hand': turn.hand, 'turn': turn.index, 'seat': mySeat, 'round': round, ...m});

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
    if (e.round == 4 || d.gone.isNotEmpty) _resumeStalled();
  }

  /// A settled pass at a sealed table: the positions move, and the
  /// engine learns the cards this side can see.
  void _applyPass(DealSession d, int seat, TableEvent e) {
    final b = Map<String, Object?>.from(e.body);
    if (!d.acceptPass(b, verified: true)) _trace('a pass settled that the deal would not take: $e');
    final positions = [for (final p in b['positions'] as List) p as int];
    final to = (seat + game.passDirection.seatOffset) % seatCount;
    _sentPass[seat] = (to: to, positions: positions);
    _takePass(d, seat, to, positions);
  }

  /// Every settled pass of this hand, by the seat that made it: kept
  /// because one may not open here yet, and a pass the engine could
  /// not take has to be offered it again when it does ([_resumePasses]).
  final Map<int, ({int to, List<int> positions})> _sentPass = {};

  /// A settled pass offered to the engine, as far as this side can
  /// open it.
  void _takePass(DealSession d, int from, int to, List<int> positions) {
    final cards = <Card>[];
    for (final p in positions) {
      final c = d.openedCardAt(p);
      if (c == null) break;
      cards.add(Card.deck[c]);
    }
    _declareLead();
    if (cards.length != positions.length && game.knowsHand(to)) {
      // Into a seat whose hand is seen here — this seat's own, or a
      // departed seat's opened from escrow — a pass has to open too,
      // and this one will not: sealed to a secret nobody holds, or to
      // nothing at all (docs/03-fair-deal.md). The engine waits at the
      // pass rather than take a hand it cannot fill, and where the seat
      // is this one, this side says so rather than sit there looking
      // idle.
      _trace('a pass from seat $from into seat $to, whose hand is seen here, that will not open');
      if (to == mySeat) _complain(from);
      return;
    }
    game.setPass(from, cards.length == positions.length ? cards : null);
  }

  /// Every settled pass the engine has not taken, offered again: after
  /// a showing, or after the passer's own hand opened from escrow.
  void _resumePasses() {
    final d = _deal;
    if (d == null || game.phase != Phase.passing) return;
    for (final e in _sentPass.entries) {
      if (game.hasPassed(e.key)) continue;
      _takePass(d, e.key, e.value.to, e.value.positions);
    }
    if (game.phase == Phase.playing) _openPlay();
    _drainFuture();
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
      if (d.awaitsSecret(e.value)) continue;
      _stalled.remove(e.key);
      _botTurn(e.key, e.value);
    }
    if (_stalled.isEmpty && _pause == Pause.openingHand) _pause = null;
  }

  /// This side's piece of a departed seat's secret, for everyone.
  void _releaseFor(int seat) {
    final m = _deal?.releaseShare(seat);
    if (m == null) return;
    _lastReleaseAt = clock.nowMs;
    _emit(EventKind.release, {'hand': game.handNumber, 'about': seat, 'share': m['share']});
  }

  /// Every few seconds while any departed seat's secret is awaited
  /// here: say this side's pieces again, since a release lost is a
  /// table stalled.
  void _releaseTick() {
    final d = _deal;
    if (d == null || clock.nowMs - _lastReleaseAt < 5000) return;
    for (final s in d.gone) {
      if (d.awaitsSecret(s)) _releaseFor(s);
    }
  }

  // ---- a pass that will not open ----------------------------------------
  //
  // Doc 03: a passer seals the three tokens to the receiver, and
  // nobody else can tell whether what it sealed is the right thing —
  // that is the hole. A receiver left with three cards it cannot open
  // cannot play them, and would sit there looking idle until the clock
  // took its seat for a fault it did not commit. So it says so, and
  // the passer answers by showing the three in the clear. An honest
  // passer always can: the tokens are its own and it kept them. One
  // that will not is removed at whatever turn of its own is open, and
  // its hand opens from escrow, which opens the three anyway.
  //
  // The cost of answering is that the three cards become everyone's to
  // see. That is why a receiver has no reason to ask falsely — the
  // cards it would give away are the ones it just received — and why
  // an honest passer is never asked at all.

  /// Complaints heard this hand, by the seat that owes an answer.
  final Map<int, ({int to, int atMs})> _complaints = {};

  /// When this side last said a pass into its seat would not open, by
  /// passer: said again every few seconds, since a complaint lost is a
  /// seat that looks idle.
  final Map<int, int> _complainedAt = {};

  void _complain(int from) {
    if (!amSeated || _left || done || mySeat == null) return;
    if (clock.nowMs - (_complainedAt[from] ?? -10000) < 5000) return;
    _complainedAt[from] = clock.nowMs;
    _emit(EventKind.complain, {'hand': game.handNumber, 'about': from, 'seat': mySeat}, everywhere: true);
  }

  void _onComplain(TableEvent event) {
    if (_deal == null) return;
    if (event.hand > game.handNumber) return _defer(event);
    if (event.hand < game.handNumber) return;
    final from = event.about;
    final to = event.seat;
    if (from < 0 || from >= seatCount || to < 0 || to >= seatCount) return;
    // Only the seat the pass was into, only about a pass that was made,
    // and only about a person: a bot's pass is open to everyone, and a
    // departed seat's opens from escrow.
    final complainer = holders[to];
    if (complainer is! HumanSeat || complainer.key != event.author || !_isParticipant(event.author)) return;
    // A pass that settled here, from that seat into this one. Not
    // "the engine took it": the one seat that cannot say the engine
    // took it is the seat whose complaint this is.
    if (game.passerTo(to) != from || _sentPass[from]?.to != to || holders[from] is! HumanSeat) return;
    if (_complaints.containsKey(from)) return;
    _complaints[from] = (to: to, atMs: clock.nowMs);
    _trace('seat $to says the pass from seat $from will not open');
    _complaintTick();
    _notify();
  }

  void _onShow(TableEvent event) {
    final d = _deal;
    if (d == null) return;
    if (event.hand > game.handNumber) return _defer(event);
    if (event.hand < game.handNumber) return;
    final seat = event.seat;
    if (seat < 0 || seat >= seatCount) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != event.author) return;
    if (!d.acceptShow(Map<String, Object?>.from(event.body))) {
      _trace('a showing by seat $seat that does not open what it names');
      return;
    }
    _trace('seat $seat showed in the clear what it passed');
    _complaints.remove(seat);
    _resumePasses();
    _resumeStalled();
    _witnessHeld(seat);
    _notify();
  }

  /// Actions of [seat] this peer held its witness back from while the
  /// seat owed an answer: witnessed now that it does not.
  void _witnessHeld(int seat) {
    if (!amSeated) return;
    for (final e in List.of(_races.entries)) {
      final action = e.value.action;
      if (e.value.settled || action == null || _turnSeat[e.key] != seat) continue;
      if (action.author == signer.publicKey || _myWitness.containsKey(e.key)) continue;
      _witness(e.key, action);
      _settle(e.key);
    }
  }

  /// A second's worth of what a complaint comes to: this seat answers
  /// one against it at once — there is nothing to think about, the
  /// tokens are its own and it kept them — and says its own again
  /// while it stands, since a complaint lost is a seat that looks idle.
  void _complaintTick() {
    if (!amSeated || _left || done) return;
    final d = _deal;
    final me = mySeat;
    if (d == null || me == null) return;
    // Owed by this seat: answered at once, and said again while the
    // complaint stands, since an answer lost is a seat that looks like
    // one refusing to give it.
    final sent = _sentPass[me];
    if (_complaints.containsKey(me) && sent != null && lies != Lie.sealNoAnswer) {
      if (clock.nowMs - _showedAt >= 5000) {
        final m = d.showMessage(sent.positions);
        if (m != null) {
          _showedAt = clock.nowMs;
          _emit(EventKind.show, {'hand': game.handNumber, ...m}, everywhere: true);
        }
      }
    }
    // Owed to this seat: said again until it is answered.
    if (game.phase == Phase.passing) {
      final from = game.passerTo(me);
      if (from != me && _sentPass.containsKey(from) && !game.hasPassed(from)) _complain(from);
    }
    if (_stuckOnAPass) _openTheHand('a pass sealed to nothing, unanswered, and the table waiting on the seat it was sent to');
  }

  /// Whether this seat is the one that cannot go on: it was sent a
  /// pass that will not open and nobody has answered for it. It is
  /// still at the pass while the table is somewhere in the hand, so it
  /// is in no position to say the hand is past saving; it waits to be
  /// told, by the audits turning up.
  bool get _waitingOnAPass {
    final me = mySeat;
    if (me == null || _openingAudit || game.phase != Phase.passing) return false;
    for (final e in _complaints.entries) {
      if (e.value.to != me || clock.nowMs - e.value.atMs < timeBank.fixedMs) continue;
      if (!game.hasPassed(e.key)) return true;
    }
    return false;
  }

  /// Whether the hand is past saving for want of an answer: a pass that
  /// will not open, said so and not answered within the clock a device
  /// answers by, with the table now waiting on the very seat that
  /// cannot see its own cards.
  ///
  /// Only the passer could open those three, and it will not. The seat
  /// waiting on them cannot play them, and removing it changes nothing
  /// — a bot playing its hand cannot see them either. The wait is on a
  /// turn that cannot come, which is the one thing a table must never
  /// do, so the hand is opened and given up ([_openTheHand]).
  ///
  /// The moment is the same at every peer: the turn the table is
  /// waiting at is the same turn everywhere, so the record every peer
  /// gives up is the same record.
  bool get _stuckOnAPass {
    for (final e in _complaints.entries) {
      if (clock.nowMs - e.value.atMs < timeBank.fixedMs) continue;
      if (_openTurnOf(e.value.to) != null) return true;
      if (_stalled.values.contains(e.value.to)) return true;
    }
    return false;
  }

  int _showedAt = -10000;

  void _onRelease(TableEvent event) {
    final d = _deal;
    if (d == null) return;
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
    d.acceptRelease({'about': about, 'holder': event.author, 'share': event.body['share']});
    if (was && !d.awaitsSecret(about)) {
      _trace('seat $about\'s hand is open, from ${event.author.substring(0, 4)}\'s piece and another');
      _resumeStalled();
      _resumePasses();
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
      // Whatever it was asked to show, it will not be showing: what it
      // sent opens from its escrow now, like the rest of its hand.
      _complaints.remove(seat);
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
    }
  }

  void _onLeave(TableEvent event) {
    final seat = event.seat;
    if (seat < 0 || seat >= seatCount) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != event.author) return;
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    _log(Decision(turn: turn, event: event, witnesses: {event.author}, removal: true));
    _trace('left seat $seat at $turn');
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
  // A seat not heard from for two minutes is booted at its own turn
  // without the fifteen-second wait, and nowhere else. An earlier
  // version let a peer claim the seat gone at whatever position it was
  // on, so that a turn of someone else's stuck for want of the silent
  // seat's vote could go on with one participant fewer. The chaos test
  // found what that costs: peers apply such a claim to an open turn at
  // different moments, and two claims in flight at once — each about a
  // seat that had voted at that turn — let two peers settle the turn
  // opposite ways, each with a majority of the set it believed in. A
  // removal made at the seat's own turn is the race's own decision, and
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
    _notify();
  }

  // ---- timers -------------------------------------------------------------

  void _heartbeat() {
    if (_closed) return;
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
    if (_closed) return;
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
      // Anyone not heard from for two minutes whose turn is open is
      // booted at once, for silence.
      for (final e in List.of(_races.entries)) {
        final race = e.value;
        if (race.settled || race.action != null || _myWitness.containsKey(e.key)) continue;
        final seat = _turnSeat[e.key]!;
        final h = holders[seat];
        if (h is! HumanSeat || h.key == signer.publicKey || !_isParticipant(h.key)) continue;
        if (!_silent(h.key) || !connectedToMajority || writesRefused) continue;
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
      _complaintTick();
      _bootLiars();
      _actOnDeal();
      _releaseTick();
    } else if (mySeat == null && _serving.isNotEmpty && !done) {
      _judgeAppeals();
      _releaseTick();
    }
    _notify();
  }

  int _repeatTick = 0;

  void _repeat() {
    if (++_repeatTick % 2 != 0) return;
    // What stays unsettled is said again every two seconds, by the
    // usual path; the second time, and every tenth second after, by
    // every path. An action settles in a moment when everyone heard
    // it, so one still open after four seconds may have gone to a
    // relay someone at the table cannot read, and the only way to
    // find out is to say it where they can hear.
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
      if (race.action == null && race.boots.isEmpty) continue; // nothing to say yet
      race.repeats++;
      final everywhere = race.repeats == 2 || insist;
      if (race.action != null) transport.broadcast(race.action!.toJson(), everywhere: everywhere);
      for (final b in race.boots) {
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

  /// This peer's own unsettled witnesses, kept to repeat.
  final Map<TurnId, TableEvent> _myWitnessEvents = {};

  // ---- the jury -----------------------------------------------------------
  //
  // Doc 04: every hand seats a jury drawn from whoever is online, to
  // break a deadlock the players cannot. Here: the lowest key among
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

  /// Everyone drawn for [hand], across every jury in force at it.
  Set<PublicKey> _jurorsOf(int hand) => {for (final d in _juriesFor(hand)) ...d.event.jurors};

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
  /// to have been.
  Set<PublicKey> _liveJurors(int hand) {
    final live = <PublicKey>{};
    for (final d in _juriesFor(hand)) {
      final drawn = _juryAt[d.event.id] ?? 0;
      for (final j in d.event.jurors) {
        final heard = _jurorHeard[j];
        if ((heard != null && clock.nowMs - heard < 30000) || clock.nowMs - drawn < 30000) live.add(j);
      }
    }
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
    if (own && _liveJurors(hand).length >= 2) return;
    final quiet = _jurorsOf(hand).difference(_liveJurors(hand));
    final candidates = p.online(withinMs: 15000).difference(_humans).difference(quiet);
    if (candidates.isEmpty) {
      if (!needsJuror) _trace('nobody online to draw a jury from');
      needsJuror = true;
      if (clock.nowMs - _lastCalledAt >= 10000) {
        _lastCalledAt = clock.nowMs;
        p.callForJuror(spec.id);
      }
      return;
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
    try {
      _everProposed.addAll(event.jurors);
    } catch (_) {}
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
    if (race == null || race.settled) return;
    if (!amSeated || _left || event.author == signer.publicKey) return;
    if (_myJuryWitnessEvents.containsKey(event.id) || !_acceptableJury(event)) return;
    _witnessJury(event);
    _settleJury(event.id);
  }

  /// Whether to back a proposal: the draw is what the snapshot gives,
  /// the snapshot holds nobody at this table, every juror is someone
  /// this peer has seen online too, and this peer is not already
  /// behind another live proposal for the hand.
  bool _acceptableJury(TableEvent e) {
    final snapshot = e.snapshot;
    final jurors = e.jurors;
    if (jurors.isEmpty || snapshot.any(_humans.contains)) return false;
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
      if (earlier != null && earlier.settled && _liveJurors(e.hand).length >= 2) return false;
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
    _trace('jury for hand ${e.hand}: ${e.jurors.map((k) => k.substring(0, 4))} by ${race.forAction.length}');
    final p = presence;
    if (p != null && amSeated) {
      for (final j in e.jurors) {
        p.summon(j, {'table': spec.toJson(), 'hand': e.hand, 'jurors': e.jurors, 'jury': e.id});
      }
    }
    _notify();
  }

  /// Once a second at a seat: propose when it is this peer's place to,
  /// and appeal every stuck turn to the jury, every ten seconds. Stuck
  /// is a race that split, or any open turn while the table is paused
  /// — a table of two with one gone quiet claims nothing, by design,
  /// and has nothing to split; it asks.
  void _juryTick() {
    _proposeJury();
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
  void serveFor(int hand, List<PublicKey> jurors) {
    if (mySeat != null) return;
    _serving[hand] = jurors;
    _notify();
  }

  /// Whether this client is still a juror of the hand in play or one
  /// to come; false once the table has moved past every hand it served,
  /// the game is over, or nobody at the table has been heard for five
  /// minutes — a table everyone walked away from is nobody's to serve.
  bool get serving =>
      mySeat == null &&
      !done &&
      (_serving.keys.any((h) => h >= game.handNumber) || _jurorsOf(game.handNumber).contains(signer.publicKey)) &&
      participants.any((k) => clock.nowMs - (_lastHeard[k] ?? 0) < 5 * 60 * 1000);

  /// A juror that stops: no more heartbeats, no more verdicts. The
  /// table notices the silence and draws another.
  void stopServing() {
    _serving.clear();
    _appealSeenAt.clear();
  }

  void _onAppeal(TableEvent event) {
    if (mySeat != null && event.seat == mySeat && event.author != signer.publicKey) _insist(event.turn);
    if (mySeat != null || !_isParticipant(event.author)) return;
    if (!_orderFor(event.hand).contains(signer.publicKey)) return;
    _appealSeenAt.putIfAbsent(event.turn, () => clock.nowMs);
    _carryingHand = event.hand;
    _judgeAppeals();
  }

  final Map<TurnId, int> _relayedAt = {};

  void _judgeAppeals() {
    for (final turn in List.of(_appealSeenAt.keys)) {
      final race = _races[turn];
      if (race == null) continue; // still catching up to it
      if (race.settled) {
        _appealSeenAt.remove(turn);
        _relayedAt.remove(turn);
        continue;
      }
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
    if (holder is! HumanSeat) return;
    final of = _participantsAt(turn);
    final needed = _majority(of);
    final forAction = race.forAction.intersection(of);
    final forRemoval = race.forRemoval.intersection(of);
    final awake = of.difference(forAction).difference(forRemoval).where((k) => !_silent(k)).toSet();
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
    if (!_silent(holder.key)) {
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
  void _onVerdict(TableEvent event) {
    final turn = event.turn;
    if (!_jurorsOf(turn.hand).contains(event.author) && !_orderFor(turn.hand).contains(event.author)) return;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    final race = _races[turn];
    if (race == null) return _defer(event);
    if (race.settled) return _catchUp(turn);
    final seat = _turnSeat[turn]!;
    if (event.seat != seat) return;
    final holder = holders[seat];
    if (holder is! HumanSeat) return;
    final ruled = event.ruled;
    if (ruled == null || ruled.table != spec.id || ruled.seat != seat || ruled.turn != turn) return;
    final of = _participantsAt(turn);
    if (event.side == 'action') {
      if (ruled.author != holder.key) return;
      if (ruled.kind != EventKind.pass && ruled.kind != EventKind.play && ruled.kind != EventKind.deal) return;
      if (!_valid(ruled, seat)) return;
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
    var i = record.length;
    while (i > 0 && record[i - 1].compareTo(d) > 0) {
      i--;
    }
    record.insert(i, d);
  }

  void _notify() {
    if (_closed) return;
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

class _Race {
  TableEvent? action;
  final List<TableEvent> boots = [];

  /// How many times this peer has said the race's evidence again.
  int repeats = 0;

  /// Every witness received, so the whole decision can be handed to a
  /// peer that missed some of it.
  final List<TableEvent> witnessEvents = [];
  final Set<PublicKey> forAction = {};
  final Set<PublicKey> forRemoval = {};
  bool settled = false;
  bool split = false;
}
