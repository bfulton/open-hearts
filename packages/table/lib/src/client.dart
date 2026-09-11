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
/// Not in this version: the jury, so at two humans an inferred removal
/// cannot reach a majority and the table pauses and says so; a
/// verifiable deal, so the deal is a shared seed; and any defence
/// against a participant signing both sides of a race, which honest
/// clients never do and the record's verification exposes after the
/// fact.
library;

import 'dart:async';

import 'package:engine/engine.dart';

import 'clock.dart';
import 'events.dart';
import 'model.dart';
import 'signing.dart';
import 'spec.dart';
import 'transport.dart';

/// Why a table is not moving.
enum Pause {
  /// A removal is proposed that the players at the table cannot decide
  /// among themselves — two humans, one silent.
  waitingForJury,

  /// A removal is proposed and there are not enough peers reachable to
  /// carry it: the table is partitioned or most of it has gone quiet.
  waitingForPeers,
}

/// A settled turn or a departure, as it goes in the record.
class Decision {
  const Decision({
    required this.turn,
    required this.event,
    required this.witnesses,
    this.removal = false,
    this.among = const {},
  });

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
  String get key => removal ? 'out@$turn#${event.seat}' : event.id;

  /// Canonical position in a record. Pass turns are concurrent and
  /// settle in a different order at every peer; ordering by turn, with
  /// departures ahead of the action at the same turn, makes every
  /// peer's record the same list.
  int compareTo(Decision other) {
    if (turn.hand != other.turn.hand) return turn.hand.compareTo(other.turn.hand);
    // The pass turns are one position: departures during the pass come
    // before every pass of the hand, then the passes by seat.
    final a = turn.isPass ? -1 : turn.index;
    final b = other.turn.isPass ? -1 : other.turn.index;
    if (a != b) return a.compareTo(b);
    if (removal != other.removal) return removal ? -1 : 1;
    return event.seat.compareTo(other.event.seat);
  }

  @override
  String toString() => '$turn ${removal ? 'OUT' : 'ok'} $event by ${witnesses.length}';
}

class TableClient {
  TableClient({
    required this.spec,
    required this.signer,
    required this.transport,
    required this.clock,
    this.bootAfterMs = 15000,
    this.silenceAfterMs = 90000,
    this.heartbeatMs = 5000,
  })  : game = HeartsGame(seed: spec.seed),
        holders = List.of(spec.seats),
        _humans = {for (final h in spec.seats) if (h is HumanSeat) h.key};

  final TableSpec spec;
  final Signer signer;
  final Transport transport;
  final Clock clock;
  final int bootAfterMs;
  final int silenceAfterMs;
  final int heartbeatMs;

  final HeartsGame game;

  /// Who holds each seat now; humans become bots as they go.
  final List<SeatHolder> holders;

  /// Every human who sat down.
  final Set<PublicKey> _humans;

  /// The humans still at the table.
  Set<PublicKey> get participants => _humans.difference(_removedAt.keys.toSet());

  /// Every settled turn and departure, in canonical order.
  final List<Decision> record = [];

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

  bool get done => game.phase == Phase.gameOver;

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
      amSeated && game.phase == Phase.passing && game.passOf(mySeat!) == null && !_left && !_acted(TurnId.pass(game.handNumber, mySeat!));

  /// It is the player's turn and they have not yet played into it.
  bool get awaitingMyPlay =>
      amSeated && game.phase == Phase.playing && game.currentSeat == mySeat && !_left && !_acted(TurnId.play(game.handNumber, _playIndex));

  bool _acted(TurnId turn) => _races[turn]?.action != null;

  /// Whether the Boot button shows for [seat]: a human's turn, open for
  /// fifteen seconds by this peer's clock.
  bool canBoot(int seat) {
    if (!amSeated || seat == mySeat || holders[seat] is! HumanSeat) return false;
    if (!connectedToMajority) return false;
    if (_catchingUp((holders[seat] as HumanSeat).key)) return false;
    final t = _openTurnOf(seat);
    return t != null && (clock.nowMs - _openedAt[t]! >= bootAfterMs || _silent((holders[seat] as HumanSeat).key));
  }

  /// A peer whose recent heartbeats put it behind this one is not idle,
  /// it is still receiving the game; nobody boots a player for that.
  bool _catchingUp(PublicKey key) {
    final pos = _lastPosition[key];
    if (pos == null || !_recent(key)) return false;
    final (hand, step) = pos;
    return hand < game.handNumber || (hand == game.handNumber && step < this.step);
  }

  /// Milliseconds until [canBoot] for [seat], or null when there is no
  /// open turn for it.
  int? bootCountdownMs(int seat) {
    final t = _openTurnOf(seat);
    if (t == null) return null;
    final holder = holders[seat];
    if (holder is HumanSeat && _silent(holder.key)) return 0;
    final left = bootAfterMs - (clock.nowMs - _openedAt[t]!);
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
    if (_future.isNotEmpty) b.writeln('  deferred ${_future.length}: ${_future.take(4).map((e) => '${e.kind.name}@${e.turn}')}');
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

  /// Where each peer last said it stood, from its heartbeats.
  final Map<PublicKey, (int, int)> _lastPosition = {};
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
    _emit(EventKind.pass, {
      'hand': game.handNumber,
      'turn': turn.index,
      'seat': mySeat,
      'cards': [for (final c in cards) c.code],
    });
  }

  void play(Card card) {
    if (!awaitingMyPlay) return;
    if (!game.legalPlaysFor(mySeat!).contains(card)) return;
    final turn = TurnId.play(game.handNumber, _playIndex);
    _emit(EventKind.play, {
      'hand': game.handNumber,
      'turn': turn.index,
      'seat': mySeat,
      'card': card.code,
    });
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
    if (_acted(at) || votedHere) {
      at = at.isPass ? TurnId.play(at.hand, 0) : TurnId.play(at.hand, at.playIndex + 1);
    }
    _emit(EventKind.leave, {'hand': at.hand, 'turn': at.index, 'seat': mySeat});
  }

  /// Presses Boot on [seat]. A no-op unless [canBoot].
  void boot(int seat) {
    if (!canBoot(seat)) return;
    final turn = _openTurnOf(seat)!;
    if (_myWitness.containsKey(turn)) return;
    _emit(EventKind.boot, {'hand': turn.hand, 'turn': turn.index, 'seat': seat});
  }

  void _emit(EventKind kind, Map<String, Object?> body) {
    final event = TableEvent.sign(signer, table: spec.id, kind: kind, body: body);
    if (kind != EventKind.heartbeat) _trace('emit ${kind.name} $body');
    transport.broadcast(event.toJson());
    _accept(event);
  }

  // ---- positions ---------------------------------------------------------

  int get _playIndex => game.tricksPlayed * seatCount + game.trick.length;

  /// Where a claim about [seat] is made: the seat's own pass turn during
  /// the pass, otherwise the play turn that is open.
  TurnId _positionOf(int seat) => game.phase == Phase.passing
      ? TurnId.pass(game.handNumber, seat)
      : TurnId.play(game.handNumber, _playIndex);

  /// Negative when [t] is behind this peer, zero when it is current
  /// here, positive when it is still to come. During the pass every pass
  /// turn of the hand is current, settled or not: a removal made at a
  /// seat's pass turn has to be placeable by peers whose other pass
  /// turns have already settled.
  int _compare(TurnId t) {
    if (t.hand != game.handNumber) return t.hand.compareTo(game.handNumber);
    if (game.phase == Phase.passing) return t.isPass ? 0 : 1;
    if (t.isPass) return -1;
    return t.playIndex.compareTo(_playIndex);
  }

  /// Whether a removal at [a] counts for a race at [b]. The pass turns
  /// of a hand are concurrent, so a removal made during the pass counts
  /// for every pass of that hand, whichever seat's turn it names.
  static bool _atOrBefore(TurnId a, TurnId b) {
    if (a.hand != b.hand) return a.hand < b.hand;
    final ai = a.isPass ? -1 : a.index;
    final bi = b.isPass ? -1 : b.index;
    return ai <= bi;
  }

  /// The set a majority at [turn] is of: everyone not removed by then.
  Set<PublicKey> _participantsAt(TurnId turn) =>
      {for (final k in _humans) if (!_removedAt.containsKey(k) || !_atOrBefore(_removedAt[k]!, turn)) k};

  static int _majority(Set<PublicKey> of) => of.length ~/ 2 + 1;

  // ---- the hand ---------------------------------------------------------

  void _openHand() {
    played.clear();
    step = 0;
    if (game.phase == Phase.passing) {
      // Every pass turn opens before any bot passes: a bot's pass closes
      // its turn and drains what was deferred, and a human's pass held
      // there has to find its turn open or it is lost.
      for (var s = 0; s < seatCount; s++) {
        _openTurn(TurnId.pass(game.handNumber, s), s, botActs: false);
      }
      for (var s = 0; s < seatCount; s++) {
        if (holders[s] is BotSeat) _botActs(TurnId.pass(game.handNumber, s), s);
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
      _botActs(turn, seat);
    }
  }

  void _botActs(TurnId turn, int seat) {
    final bot = Bot(persona: (holders[seat] as BotSeat).persona);
    if (turn.isPass) {
      game.setPass(seat, bot.choosePass(game.handOf(seat)));
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
    if (game.phase == Phase.passing) {
      // Waits for every seat's pass; the next turns open with play.
      _drainFuture();
      return;
    }
    if (game.pendingTrick != null) game.collectTrick();
    if (game.phase == Phase.handOver) {
      // The table does not wait on anyone to look at the score sheet;
      // a view that wants to show it takes it from here.
      lastHand = (
        hand: game.handNumber,
        scores: game.handScores,
        totals: game.totals,
        moonShooter: game.moonShooter,
      );
      game.nextHand();
      _openHand();
    } else if (game.phase == Phase.playing) {
      _openPlayTurn();
    }
    _drainFuture();
    _notify();
  }

  TurnId? _openTurnOf(int seat) {
    for (final e in _races.entries) {
      if (!e.value.settled && _turnSeat[e.key] == seat) return e.key;
    }
    return null;
  }

  // ---- receiving --------------------------------------------------------

  void _onMessage(PublicKey from, Map<String, Object?> json) {
    if (_closed) return;
    final event = TableEvent.parse(json);
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
    if (event.author != from && _humans.contains(event.author) && !_seen.contains(event.id) && !_alreadyPast(event)) {
      _lastHeard[event.author] = clock.nowMs;
    }
    if (event.kind == EventKind.heartbeat) {
      if (event.author != from) return;
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
      _lastPosition[from] = (event.hand, event.step);
      _carryForward(from, event.hand, event.step);
      return;
    }
    if (_seen.contains(event.id)) {
      // Seen before, and sent again: the sender is still waiting on a
      // turn this peer may have settled. Answer with what settled it.
      if (event.kind != EventKind.leave) _catchUp(event.turn);
      return;
    }
    _accept(event);
    _notify();
  }

  /// Whether [event] is about a position this peer has already passed.
  bool _alreadyPast(TableEvent event) {
    if (event.kind == EventKind.heartbeat) {
      return event.hand < game.handNumber || (event.hand == game.handNumber && event.step < step);
    }
    final t = event.turn;
    if (t.hand != game.handNumber) return t.hand < game.handNumber;
    final here = game.phase == Phase.passing ? 0 : TurnId.passTurns + game.tricksPlayed * seatCount + game.trick.length;
    return t.index < here;
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
        _onAction(event);
      case EventKind.boot:
      case EventKind.absent:
        _onBoot(event);
      case EventKind.leave:
        _onLeave(event);
    }
  }

  void _defer(TableEvent event) {
    _seen.remove(event.id);
    _future.add(event);
    if (event.kind != EventKind.witness) _trace('defer ${event.kind.name}@${event.turn} from ${event.author.substring(0, 4)}');
  }

  void _drainFuture() {
    if (_future.isEmpty) return;
    final again = List.of(_future);
    _future.clear();
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
    if (live.first != signer.publicKey && clock.nowMs - _behindSince[asker]! < heartbeatMs * 2 + 1000) return;
    var h = hand;
    var st = step;
    for (var n = 0; n < carryWindow; n++) {
      if (h > game.handNumber || (h == game.handNumber && st >= this.step)) return;
      final passes = PassDirection.forHand(h) == PassDirection.hold ? 0 : TurnId.passTurns;
      final turn = st < passes ? TurnId.pass(h, 0) : TurnId.play(h, st - passes);
      if (upTo != null && (h > upTo.hand || (h == upTo.hand && turn.index > upTo.index))) return;
      _catchUp(turn);
      st++;
      if (st >= passes + playsPerHand) {
        h++;
        st = 0;
      }
    }
  }

  /// Turns handed over per heartbeat to a peer behind.
  static const carryWindow = 8;

  /// When each peer was first seen behind, for the turn-taking above.
  final Map<PublicKey, int> _behindSince = {};

  /// When each removed seat was last carried forward.
  final Map<PublicKey, int> _lastTold = {};

  /// A turn's position in the hand's step count.
  int _stepOf(TurnId t) {
    final passes = PassDirection.forHand(t.hand) == PassDirection.hold ? 0 : TurnId.passTurns;
    return t.isPass ? 0 : passes + t.playIndex;
  }

  /// Steps in a hand after the pass: every card.
  static const playsPerHand = seatCount * 13;

  void _catchUp(TurnId turn) {
    // The pass turns of a hand are concurrent; a peer behind at the
    // pass needs all of them, and they count as one for the limit.
    final turns = turn.isPass ? [for (var s = 0; s < seatCount; s++) TurnId.pass(turn.hand, s)] : [turn];
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
    for (final t in settled) {
      _sendEvidence(t);
    }
    for (final d in record) {
      if (d.removal && !settled.contains(d.turn)) _sendEvidence(d.turn);
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
  static const catchUpPerSecond = 12;
  static const catchUpBurst = 48;

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

  void _onAction(TableEvent event) {
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
    if (!_valid(event, seat)) return;
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

  bool _valid(TableEvent event, int seat) {
    try {
      if (event.kind == EventKind.pass) {
        if (game.phase != Phase.passing || game.passOf(seat) != null) return false;
        final cards = [for (final c in event.body['cards'] as List) Card.parse(c as String)];
        if (cards.length != passSize || cards.toSet().length != passSize) return false;
        return cards.every(game.handOf(seat).contains);
      }
      if (game.phase != Phase.playing || game.currentSeat != seat) return false;
      return game.legalPlaysFor(seat).contains(Card.parse(event.body['card'] as String));
    } catch (_) {
      return false;
    }
  }

  /// A boot, by the clock or for silence: a vote against the seat's
  /// action in the race for its turn.
  void _onBoot(TableEvent event) {
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

  /// The rule for a boot: countersign when this peer agrees of its own
  /// knowledge — the seat has been on turn fifteen seconds by this
  /// clock, or has not been heard from for thirty — and it holds no
  /// play for the turn; holding the play, rebroadcast that instead,
  /// since the boot may only have been a dropped message.
  void _considerCountersigning(TurnId turn, TableEvent boot) {
    if (!amSeated || _turnSeat[turn] == mySeat) return;
    final race = _races[turn]!;
    if (race.action != null) {
      transport.broadcast(race.action!.toJson());
      return;
    }
    if (_myWitness.containsKey(turn) || !connectedToMajority) return;
    final holder = holders[_turnSeat[turn]!];
    if (holder is! HumanSeat) return;
    final agrees = clock.nowMs - _openedAt[turn]! >= bootAfterMs || _silent(holder.key);
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
    final id = event.witnessed;
    final turn = event.turn;
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
      race.settled = true;
      final e = race.action!;
      if (e.kind == EventKind.pass) {
        game.setPass(seat, [for (final c in e.body['cards'] as List) Card.parse(c as String)]);
      } else {
        final card = Card.parse(e.body['card'] as String);
        game.play(seat, card);
        played.add(card);
      }
      _log(Decision(turn: turn, event: e, witnesses: Set.of(race.forAction), among: of));
      _trace('settled $turn ${e.kind.name} by ${forAction.length}');
      _pause = null;
      _closeTurn(turn);
    } else if (forRemoval.length >= needed) {
      race.settled = true;
      _log(Decision(turn: turn, event: race.boots.first, witnesses: Set.of(race.forRemoval), removal: true, among: of));
      _trace('booted seat $seat at $turn by ${forRemoval.length}');
      _remove(seat, at: turn, how: race.boots.first.kind);
      _pause = null;
      _botActs(turn, seat);
      _reconsider();
    } else if (race.split) {
      _pause = Pause.waitingForJury; // still, whatever else was reconsidered
    } else if (race.action != null || race.forRemoval.isNotEmpty) {
      // Something proposed, and not carried. Deadlocked once neither
      // side can still reach a majority: the action needs everyone who
      // has not backed the boot, the boot everyone but the seat itself
      // who has not witnessed the action — and no vote is coming from
      // anyone this peer has not heard from for ninety seconds, who
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
  bool get connectedToMajority {
    final now = participants;
    final heard = now.where((k) => k == signer.publicKey || _recent(k)).length;
    return heard >= _majority(now);
  }

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
      _botActs(open, seat);
    }
    _reconsider();
  }

  bool _silent(PublicKey key) => clock.nowMs - (_lastHeard[key] ?? clock.nowMs) >= silenceAfterMs;

  // ---- silence -----------------------------------------------------------
  //
  // A seat not heard from for ninety seconds is booted at its own turn
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

  /// After a departure: a proposal that could not carry may carry now.
  void _reconsider() {
    _pause = null;
    for (final turn in List.of(_races.keys)) {
      if (!_races[turn]!.settled) _settle(turn);
    }
    _notify();
  }

  // ---- timers -------------------------------------------------------------

  void _heartbeat() {
    if (_closed) return;
    if (amSeated && !_left) {
      _emit(EventKind.heartbeat, {'hand': game.handNumber, 'step': step});
    }
    // Behind a peer heard lately: say so every second, since a heartbeat
    // is what brings the missing turns.
    _timers.add(clock.schedule(_behind ? 1000 : heartbeatMs, _heartbeat));
  }

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
    if (amSeated && !_left && !done) {
      _repeat();
      // Cut off from the table? Say so, rather than claim anything.
      final stuck = _races.values.any((r) => !r.settled);
      if (!connectedToMajority && stuck && _pause == null) {
        _pause = participants.length <= 2 ? Pause.waitingForJury : Pause.waitingForPeers;
      } else if (connectedToMajority && _pause == Pause.waitingForPeers && !_races.values.any((r) => r.forRemoval.isNotEmpty)) {
        _pause = null;
      }
      // Anyone not heard from for ninety seconds whose turn is open is
      // booted at once, for silence.
      for (final e in List.of(_races.entries)) {
        final race = e.value;
        if (race.settled || race.action != null || _myWitness.containsKey(e.key)) continue;
        final seat = _turnSeat[e.key]!;
        final h = holders[seat];
        if (h is! HumanSeat || h.key == signer.publicKey || !_isParticipant(h.key)) continue;
        if (!_silent(h.key) || !connectedToMajority) continue;
        _emit(EventKind.absent, {'hand': e.key.hand, 'turn': e.key.index, 'seat': seat});
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
    }
    _notify();
    _timers.add(clock.schedule(1000, _tick));
  }

  int _repeatTick = 0;

  void _repeat() {
    if (++_repeatTick % 2 != 0) return;
    for (final e in List.of(_races.entries)) {
      final race = e.value;
      if (race.settled) continue;
      // A split race changes only when the jury comes, or the network
      // heals and evidence arrives on its own; repeating its evidence
      // every two seconds to peers who already have it is noise on a
      // shared relay. Every half minute is enough to say it is still
      // split.
      if (race.split && _repeatTick % 30 != 0) continue;
      if (race.action != null) transport.broadcast(race.action!.toJson());
      for (final b in race.boots) {
        transport.broadcast(b.toJson());
      }
    }
    for (final e in _myWitnessEvents.entries) {
      if (_races[e.key]?.settled == false) transport.broadcast(e.value.toJson());
    }
  }

  /// This peer's own unsettled witnesses, kept to repeat.
  final Map<TurnId, TableEvent> _myWitnessEvents = {};

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

  /// Every witness received, so the whole decision can be handed to a
  /// peer that missed some of it.
  final List<TableEvent> witnessEvents = [];
  final Set<PublicKey> forAction = {};
  final Set<PublicKey> forRemoval = {};
  bool settled = false;
  bool split = false;
}
