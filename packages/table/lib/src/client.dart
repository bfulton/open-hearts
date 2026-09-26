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
    step = 0;
    // The hand's jurors are the hand's to reach: a jury carried for an
    // earlier hand still serves until relieved, and a new one changes
    // who there is to dial.
    _reachOut();
    _proposeJury();
    if (spec.sealed) {
      _handOpenedAt = clock.nowMs;
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

  /// The custodians a piece is worth sealing to: the first few still
  /// being heard from, in the escrow's own order. Every custodian
  /// holds a piece of its own, so one more opens the seat, and the
  /// side that has to open it is the one that will say the seat's
  /// moves — the first of this list ([_firstToSay]). The next two are
  /// there so that its going does not cost another round of releases.
  ///
  /// Said again every few seconds from a fresh reading, so a list
  /// drawn up when somebody was still being heard corrects itself.
  Set<int> _whoNeedsIt(int hand) {
    final live = _liveJurors(hand);
    final order = _custodiansNow(hand);
    const want = escrowThreshold + 1;
    final out = <int>{};
    for (var i = 0; i < order.length && out.length < want; i++) {
      if (live.contains(order[i])) out.add(i + 1);
    }
    // And filled out from the order itself where too few are known to
    // be live, so that the count is always met. A juror hears the
    // table rather than its fellow jurors — it dials the seats and
    // they dial it, and the jury never dials itself ([_reachOut]) — so
    // its reading of which of them are about runs behind theirs. In
    // the simulator that reading comes up short of the three about one
    // time in fourteen, at a mean of 2.86, which is often enough that
    // the fill is what the count rests on rather than a safeguard
    // against something rare. Sealed to a custodian that has gone is a
    // few bytes wasted; sealed to too few is a seat the hand stops
    // at.
    for (var i = 0; i < order.length && out.length < want; i++) {
      out.add(i + 1);
    }
    return out;
  }

  /// Whether the hand's first jury has stood long enough here to seal
  /// a deal to: it settled at least [_juryFirmMs] ago, so a draw that
  /// belongs before it has had time to arrive.
  ///
  /// Or, where no jury has been carried here yet, long enough since
  /// this side was summoned into one ([_servingSince]). A juror hears
  /// its summons about a second before the event that drew it, and
  /// without this it waited out the ten-second escape below instead.
  bool _juryFirm(int hand) {
    final drawn = _juriesDrawnFor(hand);
    final at = drawn.isEmpty ? _servingSince[hand] : _juryAt[drawn.first.event.id];
    return at != null && clock.nowMs - at >= _juryFirmMs;
  }

  /// And it is free, which is why it is this rather than nothing.
  /// Over twenty seeded hands (`tool/time_to_deal.dart`) a sealed
  /// deal takes the same time at zero, one, two, three and four
  /// seconds. The spread those numbers used to show — 6.55 s where
  /// nothing went missing and 15.41 s where something did — was
  /// never this wait; it was a deal step thrown away for arriving
  /// just before the jury that vouches for it ([_onAction]), and it
  /// is gone: every one of the twenty now deals in 6.6 s.
  static const _juryFirmMs = 2000;

  /// Whether this side is the one to say a given-up seat's moves: the
  /// first of the hand's custodians, in the escrow's own order, that
  /// is still being heard from.
  bool _firstToSay(int hand) {
    final live = _liveJurors(hand);
    for (final k in _custodiansNow(hand)) {
      if (live.contains(k)) return k == signer.publicKey;
    }
    return false;
  }

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
    // of that order everywhere and the next one is first. The seat's
    // own juror, back from wherever it was, still speaks for itself.
    //
    // Every side that will say nothing stops here — which is every
    // player, since a bot seat's pieces are sealed to the jury and no
    // player will ever hold its key. Not its deal steps and not its
    // audit, though: those are settled by each side for itself below,
    // with nothing said by anyone.
    if (heldHere && !turn.isDeal && !turn.isAudit) {
      if (botHolders(turn.hand)[seat] != signer.publicKey && !_firstToSay(turn.hand)) return;
    }
    if (d != null) {
      if (d.awaitsSecret(seat)) return _stall(turn, seat);
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
      case EventKind.topup:
        _onTopUp(event);
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
    // Once each: a peer far behind is repeated at for minutes, and a
    // list that grew by every repeat was drained, and grown, at every
    // turn it closed.
    if (!_futureIds.add(event.id)) return;
    _future.add(event);
    if (event.kind != EventKind.witness && event.kind != EventKind.release && event.kind != EventKind.topup) {
      _trace('defer ${event.kind.name}@${event.turn} from ${event.author.substring(0, 4)}');
    }
  }

  final Set<String> _futureIds = {};

  void _drainFuture() {
    if (_future.isEmpty) return;
    final again = List.of(_future);
    _future.clear();
    _futureIds.clear();
    for (final e in again) {
      // Seen, until it is taken up here. A deferred event used to be
      // put back to unseen so that a copy said again would be read
      // afresh — but the copy held here is the same event, and the
      // drain below reads it anyway. All that did was make every
      // repeat of it cost a signature check: a juror carried the
      // record put two hundred parts by, and paid for all of them
      // again at every carry, which is how one fell far enough behind
      // to stop catching up at all.
      _seen.remove(e.id);
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
  /// costs the table a copy per peer. That was most of what a hand
  /// said. A window is twelve turns and each of them sent every
  /// departure in the record, every jury and every one of the jury's
  /// witnesses — the same events twelve times over, and again on the
  /// next heartbeat. Now an event goes at most once per
  /// [carryRepeatMs], whoever is asking and however many turns want
  /// it; a peer that missed it asks again and gets it after that, and
  /// the budget it no longer spends goes on turns the asker has not
  /// seen at all.
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
  ///
  /// That wait looked for a while like the largest thing in a sealed
  /// deal, and this window like the thing to change. It was not. A
  /// peer waiting the window out is a peer that needed carrying, and
  /// what was worth fixing was its needing to be carried at all
  /// ([_onAction]). Three ways of letting a copy through sooner were
  /// measured — a memory per asker, a way past the window for a peer
  /// asking twice from one place, the same narrowed to the turn it
  /// named — and each of them bought, at between a tenth and three
  /// times the traffic, what keeping one event bought for nothing.
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

  bool _jurorRecent(PublicKey j) => clock.nowMs - (_jurorHeard[j] ?? _never) < 30000;

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
    if (!_mayAct(seat, event.author, turn.hand)) {
      // For a bot seat's deal step, as below: a judgement about what
      // this side knows rather than about the event. Who may act for
      // a bot seat is any juror of the hand ([_mayAct]), and a juror
      // brought on mid-hand reads the hand's juries the wrong way
      // round — the redraw that summoned it before the draw the seats
      // were dealt to — so the seat's true holder is a stranger here
      // for a moment and its step arrives before the jury that says
      // otherwise. Kept for the drain.
      //
      // Dropping it left a juror brought on late unable to finish the
      // hand at all: the step is dropped, its id stays seen, and
      // every copy said again after that is read as the sender being
      // behind rather than as the step this side is missing — so the
      // seat's keys never arrived, nothing sealed to that seat could
      // be opened, and no part of a share made out to it could be
      // taken up.
      //
      // A person's seat is not this: who may act for it is its own
      // key and nothing this side learns later changes that.
      if (event.kind == EventKind.deal && holders[seat] is! HumanSeat) return _defer(event);
      return;
    }
    if (!_valid(event, seat)) {
      // Not valid *here, now*, which is not the same as wrong. A deal
      // step is checked against things this side may not have yet:
      // round 0 names the custodians it sealed to and is refused
      // until they have all been seen proposed ([_validDeal]), and a
      // juror hears a hand's jury a moment after the table does. So
      // it is kept and looked at again whenever that changes
      // ([_drainFuture]) rather than dropped.
      //
      // Dropping it cost the deal nine seconds in most hands. The
      // event arrives, is refused by a hair — twenty milliseconds
      // before the jury it was waiting on, in the run that turned
      // this up — and from then on the only way back to it is
      // somebody saying it again, which the carry window holds off
      // for eight seconds ([carryRepeatMs]). Keeping the copy in hand
      // costs nothing and asks nobody for anything.
      //
      // Only a deal step, and only while its turn is still open: a
      // play or a pass that does not check out is wrong rather than
      // early, and a turn that settles some other way takes the held
      // copy with it at the next drain.
      if (event.kind == EventKind.deal) return _defer(event);
      _seen.remove(event.id);
      return;
    }
    if (race.action != null && race.action!.id != event.id) return; // equivocation: the first stands
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

  /// When the hand's deal was opened, for the wait below.
  int _handOpenedAt = 0;

  /// The deal is built once, and a bot seat's holder is fixed in it,
  /// so a table that holds bots with the jury waits for the jury
  /// before building it. The jury is proposed as the hand opens and
  /// settles a moment later, and a table with bot seats waits past
  /// that for a jury big enough to hold them — the call for a juror
  /// of last resort is what answers on a quiet night, and a bench of
  /// them is what makes the wait worth having (docs/04-live-play.md).
  /// The wait is bounded: nothing can be gained by waiting past the
  /// point where nobody is coming, and a table frozen for good is
  /// worse than one whose bots are public. So at [_jurorsWaitMs] the
  /// hand goes ahead with its bot seats in the open, which is what a
  /// deserted table with no service behind it falls back to.
  void _startDealWhenReady() {
    // A deal for *this* hand: _deal still holds the last one until the
    // new one replaces it, and testing it for null strands every hand
    // after the first.
    if (!spec.sealed || done) return;
    if (_deal != null && _deal!.hand == game.handNumber) return;
    if (_hasBotSeats) {
      // A jury that holds every bot seat — which covers waiting for a
      // jury at all, since a hand with no jury holds nothing. Short of
      // it a bot's hand is the table's to see, and at two people and
      // two bots that is the other person's hand by subtraction:
      // worth waiting on, and worth saying so while it is waited on.
      final held = botHolders(game.handNumber);
      if (clock.nowMs - _handOpenedAt < _jurorsWait && !_everyBotHeld(held)) {
        if (!_shortOfJurors) {
          _shortOfJurors = true;
          _trace('hand ${game.handNumber}: waiting for a jury that can hold the bot seats');
          _notify();
        }
        return;
      }
      if (!_everyBotHeld(held)) _fellBackOpen = true;
      if (_shortOfJurors) {
        _shortOfJurors = false;
        _notify();
      }
    }
    _startDeal();
  }

  /// Whether a hand at this table has already gone ahead with its bot
  /// seats in the open for want of jurors. The next hand still asks,
  /// and still takes a jury that can hold them if one has arrived,
  /// but it no longer waits out the whole window to find out: forty
  /// seconds is what it costs to learn that nobody is coming, and
  /// paying it once a hand at a table whose service is down would be
  /// most of the table's life.
  bool _fellBackOpen = false;

  /// How long a hand waits for a jury that can hold its bot seats.
  /// Long enough for a called-for juror to come online and be drawn
  /// into a redraw or two, short enough that a table behind a service
  /// that is down still plays.
  static const _jurorsWaitMs = 40000;

  /// The window as this hand has it.
  int get _jurorsWait => _fellBackOpen ? 10000 : _jurorsWaitMs;

  /// And how long the hand's *draw* is held back for the same reason,
  /// which is ten seconds less: a jury proposed at the end of its
  /// window still has to carry, and a deal that gave up on the jury a
  /// moment before it landed would deal with no jury at all — bot
  /// seats in the open and nobody holding the escrow either, which is
  /// worse than either alone.
  int get _juryDrawWait => _jurorsWait - 10000;

  bool _everyBotHeld(Map<int, PublicKey> held) {
    for (final s in _botSeatsAt(game.handNumber)) {
      if (!held.containsKey(s)) return false;
    }
    return true;
  }

  bool get _hasBotSeats => holders.any((h) => h is BotSeat);

  void _startDeal() {
    final c = crypto!;
    final held = botHolders(game.handNumber);
    _heldByHand[game.handNumber] = held;
    final drawn = _juriesDrawnFor(game.handNumber);
    final from = drawn.isNotEmpty ? drawn.first.event.id : _firstSummons[game.handNumber]?.juryId;
    if (from != null) _heldFrom[game.handNumber] = from;
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
      // The deal's notion of this side's seat is not the table's: a
      // juror sits at no seat here and still acts for the bot seat it
      // holds.
      mySeat: amSeated ? mySeat : _seatHeldHere(held),
      myKey: signer.publicKey,
      wrap: signer.sharedSecretWith,
      random: _random,
    );
    _dealsByHand[game.handNumber] = _deal!;
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
    // event is wrong for ([_defer]).
    //
    // Nothing used to come back to them. The drain runs when a turn
    // settles, when a jury changes and when the assignment is fixed
    // again, and the four steps this side needs to settle its first
    // turn are exactly what it is short of, so none of those ever
    // happened. The client sat at the hand's first step with the
    // whole hand in its deferred list, deferring everything the table
    // said after, and the seat it held two hands later was never
    // dealt.
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
    // Any juror of the hand, not only the one the assignment named.
    // What actually stops a juror acting for a seat is not having its
    // key: only the holder drew it, and only the jury's own escrow
    // gives it to anybody else. So the assignment says who goes first,
    // and this says who may go at all — which is what lets another
    // juror take a seat over when its holder goes quiet, with no peer
    // having to agree about who is live.
    return botHolders(hand).containsKey(seat) && _jurorsOf(hand).contains(who);
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

  /// Which juror holds which bot seat at [hand]. Empty when the table
  /// is unsealed, or when there is no jury to hold them — in which
  /// case a bot seat stays public work, which is what a table with
  /// nobody online to draw from falls back to.
  /// Fixed once the hand's deal is built: a bot seat's holder is in
  /// that deal, and a jury redrawn mid-hand would otherwise move the
  /// seat out from under it — the juror still saying its steps while
  /// everyone, itself included, had stopped accepting them for it.
  final Map<int, Map<int, PublicKey>> _heldByHand = {};

  /// And which jury each fixed assignment was read from, so that one
  /// fixed before the hand's first jury had arrived can be told from
  /// one fixed after ([_refixHolders]).
  final Map<int, String> _heldFrom = {};


  /// Who keyed each seat at [hand], by the event that settled its
  /// first deal round.
  final Map<int, Map<int, PublicKey>> _keyedBy = {};

  /// Who this side has settled the keys of, at [hand]: the seats whose
  /// holder the record has already named here. For a test, and for a
  /// view that wants to know how far the deal has been read.
  Map<int, PublicKey> keyedBy(int hand) => _keyedBy[hand] ?? const {};

  Map<int, PublicKey> botHolders(int hand) {
    // Only at a sealed table. An unsealed one has no hidden hands to
    // keep from anybody, so a juror holding a bot seat there would
    // protect nothing and only take the seat away from the peers that
    // work its moves out between them.
    if (!spec.sealed) return const {};
    final fixed = _heldByHand[hand];
    if (fixed != null) return _asKeyed(hand, Map.of(fixed));
    // In the jury's own drawn order, and across several juries in the
    // record's ([_juriesDrawnFor]) rather than in the order they
    // happened to settle here. _jurorsOf is a set whose iteration
    // order follows this peer's own history, and two peers that saw
    // the same juries in a different order would hand the same seat to
    // different jurors — each then rejecting what the other said for
    // it.
    final drawn = _juriesDrawnFor(hand);
    // Or the hand's first jury as the summons gave it, where the
    // event that drew it has not been carried here yet
    // ([_firstSummons]). Only that one: a juror topped up mid-hand is
    // summoned with the jury as it stands then, and reading the seats
    // from that list named a different holder for each of them — it
    // then made keys nobody wanted and sat out the rest of the hand.
    final jury = drawn.isNotEmpty
        ? drawn.first.event.jurors
        : (_firstSummons[hand]?.jurors ?? const <PublicKey>[]);
    return _asKeyed(hand, assignBots(jury, _botSeatsAt(hand)));
  }

  /// The bot seats a jury holds at [hand]: the ones that were already
  /// bots when the hand began.
  ///
  /// Read from the record rather than from the seat list as it stands
  /// here, because while a departure is in flight those are not the
  /// same thing. A person leaving turns their seat into a bot, and
  /// [assignBots] hands the bot seats out in order — so one seat more
  /// than another peer has shifts every juror onto a different seat,
  /// and each then refuses what the others say for theirs. Two jurors
  /// sixty-five and four hundred milliseconds behind a leave fixed
  /// two bot seats where everyone else fixed three, and the hand
  /// stopped at a seat whose keys were nobody's to make: the juror
  /// the others were waiting on was busy making a different seat's
  /// (chaos seed 5; `tool/walk.dart` prints the whole of it).
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
  /// draw it read is simply wrong. Left to stand, that peer watched
  /// the wrong juror for silence and gave up a seat nobody had lost.
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
  /// Ordered by the record rather than by event id, which is where two
  /// peers came to disagree: a juror summoned into a redraw hears the
  /// redraw that summoned it before it is carried the draw that came
  /// first, and the peer that took the later one for the first named a
  /// different juror for every bot seat. It then watched the wrong
  /// juror for silence, never gave the seat up when the real holder
  /// went, and sat out the rest of the hand.
  List<Decision> _juriesDrawnFor(int hand) => _juriesFor(hand).where((d) => d.event.hand == hand).toList()
    ..sort((a, b) {
      final by = a.compareTo(b);
      return by != 0 ? by : a.event.id.compareTo(b.event.id);
    });

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
    final from = _heldFrom[hand];
    if (from == null) return;
    final drawn = _juriesDrawnFor(hand);
    // The record's draw, against the one standing here. They agree
    // almost always — a juror fixes from its summons a second before
    // the draw it was summoned into is carried to it — and agreeing
    // is not worth a rebuild: the assignment is the same, so say the
    // jury it came from and leave the deal alone.
    final jury = drawn.isNotEmpty
        ? drawn.first.event.jurors
        : (_firstSummons[hand]?.jurors ?? const <PublicKey>[]);
    if (jury.isEmpty) return;
    final again = assignBots(jury, _botSeatsAt(hand));
    final standing = _heldByHand[hand];
    final now = drawn.isNotEmpty ? drawn.first.event.id : from;
    if (standing != null &&
        standing.length == again.length &&
        standing.entries.every((e) => again[e.key] == e.value)) {
      _heldFrom[hand] = now;
      return;
    }
    final d = _deal;
    if (d == null || d.hand != hand) return;
    _trace('hand $hand: ${now == from ? 'a seat turned into a bot after' : 'its first jury came after'} '
        'the bot seats were fixed; they are dealt again');
    _heldByHand.remove(hand);
    _heldFrom.remove(hand);
    _startDeal();
    // And the steps that settled against the assignment we have just
    // discarded are taken into the new session, in the order the deal
    // takes them. They are all still here — a settled race keeps the
    // event that settled it — so a rebuild loses nothing, and one
    // that skipped them would be a session missing a seat's keys,
    // unable to verify a single thing that came after and unable to
    // ask for any of it again.
    //
    // This is what used to stop the rebuild happening at all: a
    // settled step meant the assignment could no longer move, so a
    // juror that had read the wrong jury stayed wrong. It read the
    // wrong jury because it was brought on mid-hand and carried the
    // redraw that summoned it before the draw the seats were dealt
    // to, which is the ordinary way round for a juror joining late.
    for (var r = 0; r < TurnId.dealRounds; r++) {
      for (var seat = 0; seat < seatCount; seat++) {
        final race = _races[TurnId.deal(hand, r, seat)];
        final e = race?.action;
        if (race != null && race.settled && e != null) _applyDeal(e, seat);
      }
    }
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
    final blamed = <int>{if (d?.lied case final seat?) seat};
    for (final seat in blamed) {
      final holder = holders[seat];
      if (holder is HumanSeat) _liars.add(holder.key);
    }
    _trace('hand ${game.handNumber} given up, opened${blamed.isEmpty ? '' : '; seat(s) $blamed broke it'}');
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
  /// (docs/04-live-play.md, "When quorum is lost anyway").
  ///
  /// Without an audit, unlike the hand that is opened and given up. A
  /// hand stopped in its deal has nothing to show — nothing was passed
  /// and nothing was played — and the seat that stopped it cannot be
  /// opened to say so. The verifier takes an abandoned hand as a
  /// terminal state rather than an incomplete one.
  ///
  /// Judged here rather than agreed, as a juror's silence always is.
  /// Peers that judge it late go on waiting a little longer and then
  /// abandon the same hand; a hand number is not a matter of opinion,
  /// so they arrive at the same next hand and the events of it that
  /// came early were deferred rather than lost.
  void _giveUpUndealtHand(int seat) {
    _trace('hand ${game.handNumber}: seat $seat cannot finish its deal; the hand is given up undealt');
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
        // A juror does not seal a deal to an assignment it read a
        // moment ago. The seat it holds comes from the hand's first
        // jury, and a juror summoned into a redraw hears the redraw
        // before it is carried the draw that came first: it would
        // read itself into a seat that is somebody else's, publish
        // keys for it, and be stuck — the assignment can be put right
        // ([_refixHolders]) only until a step of the deal has settled,
        // and its own keys are such a step. A second or two of the
        // jury standing still is enough for the draw to arrive, and
        // the ten-second escape above still bounds it.
        if (!amSeated && !_juryFirm(h) && waited < 10000) return;
        // And a juror brought on after the hand's first jury makes no
        // keys for it at all. Its seat's keys were made before it
        // arrived, by somebody it may not have heard of yet: it was
        // summoned into a redraw, so the only jury it is sure of is
        // the redraw, and reading the seats from that names the wrong
        // holder for every one of them ([botHolders]). It would then
        // publish keys nobody wants — and the jurors brought on
        // beside it, computing the same wrong answer, take each
        // other's for the turn's action and can never be moved off
        // it, since the first action at a turn stands. Four jurors
        // topped up mid-hand put two of themselves out of that hand
        // for good this way.
        //
        // What it is here for is a share of the escrow, which the
        // holders make for it ([_topUpJury]). The deal is not its
        // business.
        if (_joinedLate(h)) {
          _sayOnce(h, 'brought on after hand $h\'s first jury; no keys for seat $me from here');
          return;
        }
        d.custodians = jurors.toList()..sort();
        _emitDeal(keys, 0, me, d.myKeys()!);
      }
    }
    final shuffle = open(TurnId.deal(h, 1, me));
    if (shuffle != null && d.nextShuffler == me) _emitDeal(shuffle, 1, me, d.myShuffle()!);
    final tokens = open(TurnId.deal(h, 2, me));
    if (tokens != null && d.deck != null) _emitDeal(tokens, 2, me, d.myTokens()!);
    final declare = open(TurnId.deal(h, 3, me));
    if (declare != null) {
      final m = d.myDeclaration();
      if (m != null) _emitDeal(declare, 3, me, lies == null ? m : {'seat': m['seat'], 'position': -1});
    }
    final audit = open(TurnId.audit(h, me));
    if (audit != null && (game.phase == Phase.handOver || game.phase == Phase.gameOver || _openingAudit)) {
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
      if (d.awaitsSecret(e.value)) continue;
      _stalled.remove(e.key);
      _botTurn(e.key, e.value);
    }
    if (_stalled.isEmpty && _pause == Pause.openingHand) _pause = null;
  }

  /// This side's piece of a departed seat's secret, for everyone.
  void _releaseFor(int seat) {
    // In the open once the hand is over: the audit publishes every
    // secret then, and a bot seat's piece kept from the players would
    // leave a hand only the jury could check.
    final over = _openingAudit || game.phase == Phase.handOver || game.phase == Phase.gameOver;
    final m = _deal?.releaseShare(seat, inTheOpen: over, only: over ? null : _whoNeedsIt(game.handNumber));
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

  /// The custodians of this hand's escrow, in the order everyone
  /// computes: the jury the deal was sealed to, then whoever has been
  /// drawn since, by their jury's event id and sorted within it.
  /// Append-only, because a custodian's index is its place in this
  /// list and a newcomer among the others would move every share
  /// after it (packages/deal, `extendCustodians`).
  List<PublicKey> _custodiansNow(int hand) {
    final drawn = _juriesDrawnFor(hand);
    if (drawn.isEmpty) return const [];
    final out = <PublicKey>[...drawn.first.event.jurors]..sort();
    for (final d in drawn.skip(1)) {
      for (final k in d.event.jurors.toList()..sort()) {
        if (!out.contains(k)) out.add(k);
      }
    }
    return out;
  }

  /// Gives whoever has joined the jury a share of every bot seat's
  /// secret, so that the jury tops back up instead of only shrinking
  /// (docs/04-live-play.md, "The sizing").
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
    final custodians = _custodiansNow(hand);
    if (custodians.length <= juryToHoldBots) return;
    final held = botHolders(hand);
    if (held.isEmpty) return;
    // Who this side would have answer, and whether it is one of them.
    // The jury's own liveness, not the table's: _recentWithin reads a
    // key never heard from as recent, which would put the very jurors
    // that went among the senders and leave the newcomer waiting on
    // parts nobody is making.
    final heard = _liveJurors(hand);
    final live = [
      for (var i = 1; i <= custodians.length; i++)
        if (heard.contains(custodians[i - 1])) i,
    ];
    final have = live.take(escrowThreshold).toList();
    final mine = custodians.indexOf(signer.publicKey) + 1;
    if (mine < 1 || !have.contains(mine) || have.length < escrowThreshold) return;
    for (final seat in held.keys) {
      if (!d.holdsPieceOf(seat)) continue;
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
    final drawn = _juriesDrawnFor(hand);
    return drawn.isNotEmpty && !drawn.first.event.jurors.contains(who);
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
    // Everyone learns the custodian list grew, whether or not the
    // part is theirs to open: it is what an index means.
    _growCustodians(about);
    // A part made out past the end of the list as this side has it is
    // for a custodian this side has not heard of yet — the seat's keys
    // unread, or the jury that drew the newcomer not yet settled. A
    // juror carried the record gets the parts made for it among the
    // very events that say who it is, so this is the ordinary case for
    // the one peer the part is for. Kept, not dropped: the drain after
    // each settled turn tries it again.
    final at = event.body['at'];
    if (at is! int || at < 1) return;
    // A part made out past the end of the list as this side has it is
    // for a custodian this side has not heard of yet — the seat's keys
    // unread, or the jury that drew the newcomer not yet settled. That
    // custodian may be this side itself, so a juror keeps it for the
    // drain to try again; anyone else will never be a custodian and
    // drops it.
    //
    // Within the list, this side knows its own place, and only the
    // part made out to that place is any use here. Four jurors brought
    // on at two bot seats is a lot of parts, and a peer that put every
    // one of them by was carrying two hundred events it would never
    // open, trying each of them again at every turn that settled.
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

  /// Tells the deal about the custodians drawn since it was sealed.
  void _growCustodians(int seat) {
    final d = _deal;
    if (d == null) return;
    d.extendCustodians(seat, _custodiansNow(game.handNumber));
  }

  /// A bot seat whose juror has gone quiet is a seat nobody is
  /// playing, so it is given up to the escrow like a departed
  /// person's: any [escrowThreshold] of the jury's pieces rebuild its
  /// secret ([_botActsHere], docs/04-live-play.md).
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
  ///
  /// Judged here rather than agreed, as a juror's silence always is;
  /// peers that judge it late simply take longer to accept whoever
  /// picks the seat up, and the record shows who did.
  /// How long a bot seat's holder has to take the seat's turn. A
  /// bot's move is worked out rather than thought about, so this is a
  /// deadline on a computation and not on a person: there is no grace
  /// in it and no bank behind it, which is what a person's seat gets
  /// instead (time_bank.dart).
  ///
  /// Measured rather than picked. Over six seeded hands a held bot
  /// seat answers its turn in 69 ms at the middle and 155 ms at the
  /// worst over a data channel, and 365 ms and 787 ms with a relay's
  /// latency under it — so three seconds is about four times the
  /// worst of it, and a holder that misses it is not slow, it is not
  /// working.
  static const botActsWithinMs = 3000;

  /// Whether the seat's holder has had the seat's turn in front of it
  /// for longer than that, and said nothing.
  ///
  /// Silence was the only way a bot seat could be taken off its
  /// holder, and silence is not the only way a holder fails. One that
  /// heartbeats and does nothing held the seat for as long as it
  /// liked, and the table waited: the other custodians judged it gone
  /// and released their pieces, the peers still hearing it did not,
  /// and a hand sat at one turn for minutes with the seat's own
  /// device apparently present. Heard from is not the same as playing.
  ///
  /// The seat's turn, not the deal's. A deal step is checked against
  /// things that may not have arrived, and a juror holds its keys
  /// back for a moment on purpose so that a late draw can still be
  /// read ([_juryFirmMs]) — deal steps answer at 2.9 s at the
  /// ninety-fifth percentile against a play's 0.16, and a deal step
  /// given up takes the whole hand with it ([_giveUpUndealtHand])
  /// rather than one seat. A deal that cannot finish is still caught,
  /// by silence, as it was before.
  ///
  /// And not a turn that is waiting rather than idle: a seat whose
  /// hand is not open here yet is stalled on a secret, which is the
  /// escrow working and not a holder failing.
  bool _outOfTime(int seat) {
    final turn = _openTurnOf(seat);
    if (turn == null || !(turn.isPlay || turn.isPass)) return false;
    if (_stalled.containsKey(turn)) return false;
    final race = _races[turn];
    if (race == null || race.settled || race.action != null) return false;
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
    final since = _botTurnSince.putIfAbsent('$turn|$holder', () => clock.nowMs);
    return clock.nowMs - since >= botActsWithinMs;
  }

  /// When each bot seat's turn became its holder's to take, by turn
  /// and holder. Cleared with the hand, and small in it: one entry per
  /// turn a bot seat is on.
  final Map<String, int> _botTurnSince = {};

  void _handOverQuietSeats() {
    final d = _deal;
    if (d == null) return;
    final hand = game.handNumber;
    final held = botHolders(hand);
    if (held.isEmpty) return;
    final live = _liveJurors(hand);
    final given = <int>[];
    for (final e in held.entries) {
      if (d.gone.contains(e.key)) continue;
      final quiet = !live.contains(e.value);
      final slow = _outOfTime(e.key);
      if (!quiet && !slow) continue;
      _trace('bot seat ${e.key}: its juror ${e.value.substring(0, 4)} '
          '${quiet ? 'has gone quiet' : 'has had the turn for ${botActsWithinMs ~/ 1000} seconds and said nothing'}; '
          'to the escrow');
      d.seatLeft(e.key);
      given.add(e.key);
    }
    if (given.isEmpty) return;
    // A seat given up with a step of the deal still to take is a deal
    // that cannot finish: give the hand up rather than wait on a step
    // nobody can take. Any step, not just one open now. The shuffles
    // go one at a time, so a seat whose juror goes while somebody
    // else's is awaited has no turn open yet — and when its own comes
    // round, the players cannot open a seat whose pieces are sealed to
    // the jury, and no juror says a held seat's deal steps. A table
    // that waited for that turn waited for good. Its last step is the
    // declaration; once that has settled, nothing of the deal is owed
    // by it and the escrow plays it from there.
    if (game.phase == Phase.dealing) {
      for (final seat in given) {
        if (_races[TurnId.deal(hand, TurnId.dealRounds - 1, seat)]?.settled != true) return _giveUpUndealtHand(seat);
      }
    }
    // Pieces that arrived before this side judged the seat gone were
    // put by, a release being no use for a seat still here: taken up
    // now, which is the whole of the escrow for a juror carried the
    // record long after the pieces were said.
    _drainFuture();
    // And whatever turn each seat is on was opened while a juror still
    // held it, so no side took it up. It is everyone's to work out
    // now: offered here, it plays if the pieces have come and stalls
    // until they do. Without this the table waits on a holder that is
    // never coming back, with the hand open in front of it.
    for (final seat in given) {
      _takeUpSeat(seat);
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
    _handOverQuietSeats();
    final d = _deal;
    if (d == null) return;
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
    // belong to has been built here. Dropped, they were dropped for
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
      _bootLiars();
      _actOnDeal();
      _releaseTick();
    } else if (mySeat == null && _serving.isNotEmpty && !done) {
      // Its own again, every couple of seconds, while a turn it spoke
      // for stands unsettled. A bot seat's holder is that seat's only
      // voice: a step of the deal it said once and that went missing
      // on the way to one peer was never said again, and nothing else
      // would ever come back to it — [_actOnDeal] skips a turn that
      // already has this side's action on it, the carry-forward
      // carries only what has settled somewhere, and a table waiting
      // on a deal turn is neither split nor paused, so nobody appeals
      // and [_judgeAppeals] never runs. The hand stopped there for
      // good, with every peer heartbeating and nobody at fault. A
      // seated peer has had this since the beginning ([_repeat]); a
      // juror holding a seat is as much that seat as a person is
      // theirs.
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
  /// Everyone else carrying it at two seconds as well is what made the
  /// wire what it is: at a sealed table, six parties each repeating a
  /// twelve-kilobyte shuffle argument, and the relay handing every
  /// copy to all six — the largest single item on the wire, and all of
  /// it for a case that had not happened yet
  /// (service/tool/wire_over_socket.dart).
  ///
  /// Carrying is for the case it was built for: a table cut in two, or
  /// a relay that takes one peer's events and not another's, where the
  /// only way the far side hears an action is from somebody who is not
  /// its author (matrix_test.dart, "a seat that only one peer hears
  /// directly is carried, not booted"). What makes that case urgent is
  /// the boot clock, so the boot clock is what the wait is measured
  /// against: halfway to the turn's own allowance, which leaves as long
  /// again for the carried copy to arrive and be witnessed before
  /// anybody can call the seat silent. Three seconds for a play whose
  /// bank is spent, seven and a half for a deal turn, more for a pass
  /// or a seat with time in hand.
  bool _carryDue(TurnId turn) {
    final opened = _openedAt[turn];
    final seat = _turnSeat[turn];
    if (opened == null || seat == null) return true;
    return clock.nowMs - opened >= _allowanceMs(turn, seat) ~/ 2;
  }

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
      if (race.action == null && race.boots.isEmpty) continue; // nothing to say yet
      // And the rest widen as they go ([_Race.nextRepeatTick]).
      if (_repeatTick < race.nextRepeatTick) continue;
      // What this peer has to say again: its own, always; anybody
      // else's once the turn has been open long enough for carrying
      // to be the point ([_carryAfterMs]).
      final carry = !ownOnly && _carryDue(e.key);
      final action = race.action;
      final sayAction = action != null && (carry || action.author == signer.publicKey);
      final sayBoots = [
        for (final b in race.boots)
          if (carry || b.author == signer.publicKey) b,
      ];
      if (!sayAction && sayBoots.isEmpty) continue;
      race.nextRepeatTick = _repeatTick + _repeatGap(race.repeats);
      race.repeats++;
      final everywhere = race.repeats == 2 || insist;
      if (sayAction) transport.broadcast(action.toJson(), everywhere: everywhere);
      for (final b in sayBoots) {
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
  /// to have been.
  Set<PublicKey> _liveJurors(int hand) {
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
        if ((heard != null && clock.nowMs - heard < 30000) || clock.nowMs - drawn < 30000) live.add(j);
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
    // Up to strength, not merely alive. A jury that only shrinks is
    // the shape the sizing was stuck on (docs/04-live-play.md, "The
    // sizing"); whoever is drawn now is given a share of every bot
    // seat by the ones who hold them ([_topUpJury]). The guard below
    // still stops a redraw that would seat nobody new, so a room with
    // nobody spare proposes nothing.
    if (own && _liveJurors(hand).length >= jurySize) return;
    final quiet = _jurorsOf(hand).difference(_liveJurors(hand));
    final here = p.online(withinMs: 15000).difference(_humans).difference(quiet);
    // What this table needs a jury for. Escrow needs somebody; bot
    // seats need enough jurors that a seat survives its holder going
    // (jury.dart, [juryToHoldBots]), and short of that the seats are
    // held by nobody and their hands are the table's to see.
    final wanted = spec.sealed && _hasBotSeats ? juryToHoldBots : 1;
    // Drawn from the settled ones where there are enough of them.
    // What a hand's escrow rests on is the jurors it draws still
    // being there when a bot seat has to be opened, and the size of
    // the jury is a poor lever on that where the draw is a good one
    // (docs/04-live-play.md, "The sizing"): somebody mid-game has a
    // reason to still be here in a minute, somebody glancing at the
    // lobby has none.
    //
    // A proposer may narrow its own candidates as it likes, because
    // what the table checks of a proposal is that each juror is
    // somebody *it* has seen lately, over a far wider window
    // ([_acceptableJury]). So this needs no agreement and cannot
    // deadlock — and where the settled are too few, the draw is from
    // everyone, since a jury of whoever is there beats none.
    final steady = p.settled(withinMs: 15000, forMs: jurySettledMs).difference(_humans).difference(quiet);
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
      // first draw back while a called-for juror could still arrive,
      // rather than drawing a jury now that can hold nothing. Only up
      // to [_jurorsWaitMs], after which the jury is whoever is there.
      if (!own && clock.nowMs - _handOpenedAt < _juryDrawWait) {
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
    try {
      // A jury proposed is a set of keys a deal step may seal its
      // escrow to ([_validDeal]), so a deal step held back for want
      // of them is worth looking at again the moment they arrive.
      final before = _everProposed.length;
      _everProposed.addAll(event.jurors);
      if (_everProposed.length != before) _drainFuture();
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
      // Up to strength, not merely alive — the acceptance side of the
      // same rule the proposer uses. A peer that has backed a jury
      // does not keep backing new ones while that jury is whole, but
      // a jury below strength is one to top up: whoever is drawn now
      // is given a share of every bot seat by the ones who hold them
      // (docs/04-live-play.md, "The sizing").
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
    // A jury drawn after the deal was sealed adds custodians, and the
    // escrow has to know: an index is a place in that list.
    if (e.hand == game.handNumber) {
      for (final seat in botHolders(e.hand).keys) {
        _growCustodians(seat);
      }
    }
    _trace('jury for hand ${e.hand}: ${e.jurors.map((k) => k.substring(0, 4))} by ${race.forAction.length}');
    final p = presence;
    if (p != null && amSeated) {
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
  void serveFor(int hand, List<PublicKey> jurors, {String? juryId, bool first = false}) {
    if (mySeat != null) return;
    _serving[hand] = jurors;
    _servingSince.putIfAbsent(hand, () => clock.nowMs);
    // A summons into the hand's *first* jury is the draw a bot seat's
    // holder is read from, arriving by the shorter road: kept apart
    // from the rest so that a redraw, which names the jury as it
    // stands now, never moves a seat ([botHolders]).
    if (first && juryId != null) _firstSummons.putIfAbsent(hand, () => (juryId: juryId, jurors: jurors));
    _notify();
  }

  /// Whether this side came to [hand]'s jury after the hand's first
  /// jury was drawn: it was summoned to the hand, and never into the
  /// draw that the seats were dealt to ([_firstSummons]).
  bool _joinedLate(int hand) => _serving.containsKey(hand) && _firstSummons[hand] == null;

  /// The first jury of each hand as a summons gave it, where one has
  /// said so. The event carries the same list and is the authority;
  /// this is the same thing arriving sooner, and a juror needs it
  /// sooner: one that did not know it held a seat could not make that
  /// seat's keys, so the hand stopped at them while the table waited
  /// on it.
  final Map<int, ({String juryId, List<PublicKey> jurors})> _firstSummons = {};

  /// When this side was first summoned to each hand, for [_juryFirm]:
  /// a summons is the jury arriving by another road, and it stands as
  /// long before a deal is sealed to it as a jury event would.
  final Map<int, int> _servingSince = {};

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
  bool settled = false;
  bool split = false;
}
