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
  String get key => removal ? '${event.kind.name}@$turn#${event.seat}' : event.id;

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
    this.silenceAfterMs = 30000,
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
    return t != null && clock.nowMs - _openedAt[t]! >= bootAfterMs;
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
    for (final e in _absences.entries) {
      if (e.value.settled) continue;
      b.writeln('  absent ${e.key.$1} seat ${e.key.$2}: backers ${e.value.backers.map((k) => k.substring(0, 4))}');
    }
    if (_future.isNotEmpty) b.writeln('  deferred ${_future.length}: ${_future.take(4).map((e) => '${e.kind.name}@${e.turn}')}');
    return b.toString();
  }

  // ---- internals ------------------------------------------------------

  final Map<TurnId, _Race> _races = {};
  final Map<TurnId, int> _openedAt = {};
  final Map<TurnId, int> _turnSeat = {};
  final Map<String, Set<PublicKey>> _earlyWitnesses = {};
  final Map<String, List<TableEvent>> _earlyWitnessEvents = {};
  final Map<TurnId, String> _myWitness = {};
  final Map<(TurnId, int), _Absence> _absences = {};
  final Map<PublicKey, TurnId> _removedAt = {};
  final Map<PublicKey, int> _lastHeard = {};

  /// Where each peer last said it stood, from its heartbeats.
  final Map<PublicKey, (int, int)> _lastPosition = {};
  final Set<(TurnId, PublicKey)> _mySilenceClaims = {};
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
    _incoming = transport.incoming.listen((m) => _onMessage(m.message));
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
  /// this seat has an action in flight there, in which case it is made
  /// at the next position, so the action's fate is settled first and
  /// no peer can ever hold both the action and a bot's move for the
  /// same turn.
  void leave() {
    if (!amSeated || _left) return;
    _left = true;
    var at = _positionOf(mySeat!);
    if (_acted(at)) {
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
      for (var s = 0; s < seatCount; s++) {
        _openTurn(TurnId.pass(game.handNumber, s), s);
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

  void _openTurn(TurnId turn, int seat) {
    if (_races.containsKey(turn)) return;
    _races[turn] = _Race();
    _openedAt[turn] = clock.nowMs;
    _turnSeat[turn] = seat;
    _trace('open $turn for seat $seat (${holders[seat]})');
    if (holders[seat] is BotSeat) {
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

  void _onMessage(Map<String, Object?> json) {
    if (_closed) return;
    final event = TableEvent.parse(json);
    if (event == null || event.table != spec.id) return;
    _lastHeard[event.author] = clock.nowMs;
    if (event.kind == EventKind.heartbeat) {
      _lastPosition[event.author] = (event.hand, event.step);
    }
    if (_seen.contains(event.id)) {
      // Seen before, and sent again: the sender is still waiting on a
      // turn this peer may have settled. Answer with what settled it.
      if (event.kind != EventKind.heartbeat && event.kind != EventKind.leave) _catchUp(event.turn);
      return;
    }
    _accept(event);
    _notify();
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
        _onBoot(event);
      case EventKind.absent:
        _onAbsent(event);
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

  void _catchUp(TurnId turn) {
    final race = _races[turn];
    if (race == null || !race.settled) return;
    // Once a couple of seconds per turn, whoever is asking: a peer far
    // behind repeats a lot, and every answer is itself repeated evidence
    // to everyone else.
    final last = _lastCatchUp[turn];
    if (last != null && clock.nowMs - last < 2000) return;
    _lastCatchUp[turn] = clock.nowMs;
    // Everything that decided this position: the action or the claims
    // and their witnesses, and any departure recorded here — a leave
    // that the asker missed is the commonest reason to be stuck.
    for (final d in record) {
      if (d.turn == turn) transport.broadcast(d.event.toJson());
    }
    for (final b in race.boots) {
      transport.broadcast(b.toJson());
    }
    for (final w in race.witnessEvents) {
      transport.broadcast(w.toJson());
    }
    final mine = _myWitnessEvents[turn];
    if (mine != null && !race.witnessEvents.contains(mine)) transport.broadcast(mine.toJson());
    for (final e in _absences.entries) {
      if (e.key.$1 != turn) continue;
      for (final w in e.value.witnessEvents) {
        transport.broadcast(w.toJson());
      }
      if (e.value.myWitness != null) transport.broadcast(e.value.myWitness!.toJson());
    }
  }

  void _onAction(TableEvent event) {
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    final race = _races[turn];
    if (race == null) return;
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

  void _onBoot(TableEvent event) {
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    final race = _races[turn];
    if (race == null) return;
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
    _considerCountersigning(turn, event);
    _settle(turn);
  }

  /// The rule for a boot: countersign when this peer's own clock agrees
  /// and it holds no play for the turn; holding the play, rebroadcast
  /// that instead, since the boot may only have been a dropped message.
  void _considerCountersigning(TurnId turn, TableEvent boot) {
    if (!amSeated || _turnSeat[turn] == mySeat) return;
    final race = _races[turn]!;
    if (race.action != null) {
      transport.broadcast(race.action!.toJson());
      return;
    }
    if (_myWitness.containsKey(turn) || !connectedToMajority) return;
    final agrees = boot.kind == EventKind.absent
        ? _silent((holders[_turnSeat[turn]!] as HumanSeat).key)
        : clock.nowMs - _openedAt[turn]! >= bootAfterMs;
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
    final a = _absences[(turn, event.seat)];
    if (a != null && a.claims.any((c) => c.id == id)) {
      a.backers.add(event.author);
      a.witnessEvents.add(event);
      return _settleAbsence((turn, event.seat));
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
      _remove(seat, at: turn, how: EventKind.boot);
      _pause = null;
      _botActs(turn, seat);
      _reconsider();
    } else if (race.forRemoval.isNotEmpty) {
      // Proposed, and not carried: is it ever going to be?
      final reachable = of.difference({(holders[seat] as HumanSeat).key});
      if (reachable.length < needed) _pause = Pause.waitingForJury;
      if (race.action != null && forAction.union(forRemoval).length == of.length) {
        // Everyone has voted and nobody won: only the jury can break it.
        race.split = true;
        _pause = Pause.waitingForJury;
        _trace('split at $turn: ${forAction.length} for the action, ${forRemoval.length} against');
      }
    }
  }

  /// A turn every participant has voted on without a majority either
  /// way, waiting for the jury; null when there is none.
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

  // ---- absence ------------------------------------------------------------

  void _onAbsent(TableEvent event) {
    final seat = event.seat;
    if (seat < 0 || seat >= seatCount) return;
    final turn = event.turn;
    final where = _compare(turn);
    if (where > 0) return _defer(event);
    if (where < 0) return _catchUp(turn);
    if (!_isParticipant(event.author)) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key == event.author) return;
    // The seat's own turn is open here: the claim is a vote in that
    // race, against the seat's action, exactly as a boot is — else the
    // race and the claim could each carry and contradict each other.
    // (A settled pass turn is still a current position during the pass:
    // the seat has passed and is simply absent, so the claim stands on
    // its own below.)
    final race = _races[turn];
    if (race != null && _turnSeat[turn] == seat && !race.settled) {
      race.boots.add(event);
      race.forRemoval.add(event.author);
      race.forRemoval.addAll(_earlyWitnesses.remove(event.id) ?? const {});
      race.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
      _considerCountersigning(turn, event);
      _settle(turn);
      return;
    }
    final key = (turn, seat);
    final a = _absences.putIfAbsent(key, () => _Absence());
    a.claims.add(event);
    a.backers.add(event.author);
    a.backers.addAll(_earlyWitnesses.remove(event.id) ?? const {});
    a.witnessEvents.addAll(_earlyWitnessEvents.remove(event.id) ?? const []);
    // Countersign only when this peer has heard nothing from the seat
    // for as long itself, is not itself cut off — and never a claim
    // about its own seat.
    if (amSeated && seat != mySeat && !a.backers.contains(signer.publicKey) && _silent(holder.key) && connectedToMajority) {
      a.backers.add(signer.publicKey);
      final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
        'event': event.id,
        'hand': turn.hand,
        'turn': turn.index,
        'seat': seat,
      });
      transport.broadcast(w.toJson());
      _seen.add(w.id);
      a.myWitness = w;
    }
    _settleAbsence(key);
  }

  bool _silent(PublicKey key) => clock.nowMs - (_lastHeard[key] ?? clock.nowMs) >= silenceAfterMs;

  void _settleAbsence((TurnId, int) key) {
    final a = _absences[key]!;
    if (a.settled) return;
    final (turn, seat) = key;
    final holder = holders[seat];
    if (holder is! HumanSeat) {
      a.settled = true;
      return;
    }
    if (_compare(turn) != 0) return;
    final of = _participantsAt(turn);
    final needed = _majority(of);
    if (a.backers.intersection(of).length >= needed) {
      a.settled = true;
      _log(Decision(turn: turn, event: a.claims.first, witnesses: Set.of(a.backers), removal: true, among: of));
      _trace('absent seat $seat at $turn by ${a.backers.length}');
      _remove(seat, at: turn, how: EventKind.absent);
      final open = _openTurnOf(seat);
      if (open != null) {
        _races[open]!.settled = true;
        _botActs(open, seat);
      }
      _reconsider();
    } else {
      final reachable = of.difference({holder.key});
      _pause = reachable.length < needed ? Pause.waitingForJury : Pause.waitingForPeers;
    }
  }

  /// After a departure: a proposal that could not carry may carry now.
  void _reconsider() {
    _pause = null;
    for (final turn in List.of(_races.keys)) {
      if (!_races[turn]!.settled) _settle(turn);
    }
    for (final key in List.of(_absences.keys)) {
      _settleAbsence(key);
    }
    _notify();
  }

  // ---- timers -------------------------------------------------------------

  void _heartbeat() {
    if (_closed) return;
    if (amSeated && !_left) {
      _emit(EventKind.heartbeat, {'hand': game.handNumber, 'step': step});
    }
    _timers.add(clock.schedule(heartbeatMs, _heartbeat));
  }

  /// Once a second: propose the removal of anyone silent too long,
  /// re-check boots this peer held back on until its clock agreed, and
  /// repeat what is still unsettled — a message lost to a partition or
  /// a reconnect is recovered by whoever still holds it.
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
      for (var seat = 0; seat < seatCount; seat++) {
        final h = holders[seat];
        if (h is! HumanSeat || h.key == signer.publicKey || !_isParticipant(h.key)) continue;
        if (!_silent(h.key) || !connectedToMajority) continue;
        final at = _positionOf(seat);
        if (_absences.containsKey((at, seat)) || !_mySilenceClaims.add((at, h.key))) continue;
        _emit(EventKind.absent, {'hand': at.hand, 'turn': at.index, 'seat': seat});
      }
      for (final e in List.of(_races.entries)) {
        final race = e.value;
        if (race.settled || race.boots.isEmpty || _myWitness.containsKey(e.key)) continue;
        _considerCountersigning(e.key, race.boots.first);
        _settle(e.key);
      }
      // Absence claims this peer could not back when they arrived may be
      // backable now that the silence has lasted.
      for (final e in List.of(_absences.entries)) {
        final a = e.value;
        final (turn, seat) = e.key;
        if (a.settled || seat == mySeat || a.backers.contains(signer.publicKey)) continue;
        final h = holders[seat];
        if (h is! HumanSeat || !_silent(h.key) || !connectedToMajority || _compare(turn) != 0) continue;
        a.backers.add(signer.publicKey);
        final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
          'event': a.claims.first.id,
          'hand': turn.hand,
          'turn': turn.index,
          'seat': seat,
        });
        transport.broadcast(w.toJson());
        _seen.add(w.id);
        a.myWitness = w;
        _settleAbsence(e.key);
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
      if (race.action != null) transport.broadcast(race.action!.toJson());
      for (final b in race.boots) {
        transport.broadcast(b.toJson());
      }
    }
    for (final a in _absences.values) {
      if (a.settled) continue;
      for (final c in a.claims) {
        transport.broadcast(c.toJson());
      }
      if (a.myWitness != null) transport.broadcast(a.myWitness!.toJson());
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

class _Absence {
  final List<TableEvent> claims = [];
  final Set<PublicKey> backers = {};
  final List<TableEvent> witnessEvents = [];
  TableEvent? myWitness;
  bool settled = false;
}
