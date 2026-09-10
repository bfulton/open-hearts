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
/// the participants at the time the turn opened. Then, and only then,
/// the next turn opens. A signed Leave needs no majority: it is evidence.
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
  const Decision({required this.turn, required this.event, required this.witnesses, this.removal = false});

  /// The turn settled, or the turn open when a leave or absence landed.
  final TurnId turn;

  /// The action (pass or play), the boot or absence, or the leave.
  final TableEvent event;

  /// Who backed it, the author included.
  final Set<PublicKey> witnesses;

  /// True when the seat left this turn rather than acting in it.
  final bool removal;

  /// Canonical position in a record. Pass turns are concurrent and
  /// settle in a different order at every peer; ordering by turn, with
  /// departures ahead of the action they landed beside, makes every
  /// peer's record the same list.
  int compareTo(Decision other) {
    if (turn.hand != other.turn.hand) return turn.hand.compareTo(other.turn.hand);
    if (turn.index != other.turn.index) return turn.index.compareTo(other.turn.index);
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
        participants = {for (final h in spec.seats) if (h is HumanSeat) h.key};

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

  /// The humans at the table: the set removals are decided against.
  final Set<PublicKey> participants;

  /// Everyone who ever held a seat, for the ratings at the end.
  late final List<SeatHolder> originalHolders = List.unmodifiable(spec.seats);

  /// Every settled turn and departure, in canonical order.
  final List<Decision> record = [];

  void _log(Decision d) {
    var i = record.length;
    while (i > 0 && record[i - 1].compareTo(d) > 0) {
      i--;
    }
    record.insert(i, d);
  }

  /// Turns settled in the current hand.
  int step = 0;

  /// Cards played this hand, what a seated player has seen.
  final Set<Card> played = {};

  Pause? get pause => _pause;
  Pause? _pause;

  bool get done => game.phase == Phase.gameOver;

  /// Fires after any change of state a view might show. Synchronous, so
  /// a listener sees the change in the same tick it happens — which is
  /// what lets the simulator run a whole game without yielding.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast(sync: true);

  int? get mySeat => spec.seatOf(signer.publicKey);
  bool get amSeated => mySeat != null && participants.contains(signer.publicKey);

  bool get awaitingMyPass =>
      amSeated && game.phase == Phase.passing && game.passOf(mySeat!) == null && !_left;
  bool get awaitingMyPlay =>
      amSeated && game.phase == Phase.playing && game.currentSeat == mySeat && !_left;

  /// Whether the Boot button shows for [seat]: a human's turn, open for
  /// fifteen seconds by this peer's clock.
  bool canBoot(int seat) {
    if (!amSeated || seat == mySeat || holders[seat] is! HumanSeat) return false;
    final t = _openTurnOf(seat);
    return t != null && clock.nowMs - _openedAt[t]! >= bootAfterMs;
  }

  /// Milliseconds until [canBoot] for [seat], or null when there is no
  /// open turn for it.
  int? bootCountdownMs(int seat) {
    final t = _openTurnOf(seat);
    if (t == null) return null;
    final left = bootAfterMs - (clock.nowMs - _openedAt[t]!);
    return left < 0 ? 0 : left;
  }

  // ---- internals ------------------------------------------------------

  final Map<TurnId, _Race> _races = {};
  final Map<TurnId, int> _openedAt = {};
  final Map<TurnId, int> _turnSeat = {};
  final Map<String, Set<PublicKey>> _earlyWitnesses = {};
  final Map<TurnId, String> _myWitness = {};
  final Map<int, _Absence> _absences = {};
  final Map<PublicKey, int> _lastHeard = {};
  final Map<PublicKey, int> _mySilenceClaims = {};
  final List<TableEvent> _future = [];
  final Set<String> _seen = {};
  final List<Cancel> _timers = [];
  StreamSubscription<void>? _incoming;
  StreamSubscription<void>? _drops;
  bool _left = false;
  bool _closed = false;

  void start() {
    for (final k in participants) {
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

  /// The polite exit: signed, so nobody needs to agree.
  void leave() {
    if (!amSeated || _left) return;
    _left = true;
    _emit(EventKind.leave, {'hand': game.handNumber, 'step': step, 'seat': mySeat});
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
    transport.broadcast(event.toJson());
    _accept(event);
  }

  // ---- the hand ---------------------------------------------------------

  int get _playIndex => game.tricksPlayed * seatCount + game.trick.length;

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
    _races[turn] = _Race(snapshot: Set.of(participants));
    _openedAt[turn] = clock.nowMs;
    _turnSeat[turn] = seat;
    final holder = holders[seat];
    if (holder is BotSeat) {
      _botActs(turn, seat, holder.persona);
    } else if (holder is HumanSeat && !participants.contains(holder.key)) {
      // Left already; its seat is a bot from here.
      _seatBot(seat);
      _botActs(turn, seat, (holders[seat] as BotSeat).persona);
    }
  }

  void _botActs(TurnId turn, int seat, Persona persona) {
    final bot = Bot(persona: persona);
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
      return;
    }
    if (game.pendingTrick != null) game.collectTrick();
    if (game.phase == Phase.handOver) {
      game.nextHand();
      _openHand();
      _drainFuture();
      return;
    }
    if (game.phase == Phase.playing) {
      _openPlayTurn();
      _drainFuture();
    }
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
    _accept(event);
    _notify();
  }

  void _onDisconnected(PublicKey key) {
    // Treat a closed connection as silence that began now, minus most of
    // the allowance: the transport is sure, so the timeout is short.
    if (participants.contains(key)) {
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

  bool _isAhead(int hand, int index) {
    if (hand > game.handNumber) return true;
    if (hand < game.handNumber) return false;
    return !_races.containsKey(TurnId(hand, index)) && index >= TurnId.passTurns
        ? _playIndex < index - TurnId.passTurns
        : false;
  }

  void _defer(TableEvent event) {
    _seen.remove(event.id);
    _future.add(event);
  }

  void _drainFuture() {
    final again = List.of(_future);
    _future.clear();
    for (final e in again) {
      _accept(e);
    }
  }

  void _onAction(TableEvent event) {
    final turn = event.turn;
    if (_isAhead(turn.hand, turn.index)) return _defer(event);
    final race = _races[turn];
    if (race == null || race.settled) return;
    final seat = _turnSeat[turn]!;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != event.author) return;
    if (!participants.contains(event.author)) return;
    if (!_valid(event, seat)) return;
    if (race.action != null && race.action!.id != event.id) return; // equivocation: first stands
    race.action = event;
    race.forAction.add(event.author);
    if (_earlyWitnesses.containsKey(event.id)) {
      race.forAction.addAll(_earlyWitnesses.remove(event.id)!);
    }
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
    if (_isAhead(turn.hand, turn.index)) return _defer(event);
    final race = _races[turn];
    if (race == null || race.settled) return;
    final seat = _turnSeat[turn]!;
    if (event.seat != seat) return;
    if (!participants.contains(event.author)) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key == event.author) return;
    race.boots.add(event);
    race.forRemoval.add(event.author);
    if (_earlyWitnesses.containsKey(event.id)) {
      race.forRemoval.addAll(_earlyWitnesses.remove(event.id)!);
    }
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
    if (_myWitness.containsKey(turn)) return;
    if (clock.nowMs - _openedAt[turn]! < bootAfterMs) return;
    _witness(turn, boot);
  }

  void _witness(TurnId turn, TableEvent of) {
    _myWitness[turn] = of.id;
    final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
      'event': of.id,
      'hand': turn.hand,
      'turn': turn.index,
      'seat': _turnSeat[turn],
    });
    transport.broadcast(w.toJson());
    _accept(w);
  }

  void _onWitness(TableEvent event) {
    if (!participants.contains(event.author)) return;
    final turn = event.turn;
    final race = _races[turn];
    if (race == null) {
      if (_isAhead(turn.hand, turn.index)) return _defer(event);
      return;
    }
    final id = event.witnessed;
    if (race.action?.id == id) {
      race.forAction.add(event.author);
    } else if (race.boots.any((b) => b.id == id)) {
      race.forRemoval.add(event.author);
    } else if (_absences.values.any((a) => a.claims.any((c) => c.id == id))) {
      final a = _absences.values.firstWhere((a) => a.claims.any((c) => c.id == id));
      a.backers.add(event.author);
      _settleAbsence(a);
      return;
    } else {
      _earlyWitnesses.putIfAbsent(id, () => {}).add(event.author);
      return;
    }
    _settle(turn);
  }

  void _settle(TurnId turn) {
    final race = _races[turn]!;
    if (race.settled) return;
    final needed = race.snapshot.length ~/ 2 + 1;
    final seat = _turnSeat[turn]!;
    if (race.forAction.intersection(race.snapshot).length >= needed) {
      race.settled = true;
      final e = race.action!;
      if (e.kind == EventKind.pass) {
        game.setPass(seat, [for (final c in e.body['cards'] as List) Card.parse(c as String)]);
      } else {
        final card = Card.parse(e.body['card'] as String);
        game.play(seat, card);
        played.add(card);
      }
      _log(Decision(turn: turn, event: e, witnesses: Set.of(race.forAction)));
      _pause = null;
      _closeTurn(turn);
    } else if (race.forRemoval.intersection(race.snapshot).length >= needed) {
      race.settled = true;
      _log(Decision(turn: turn, event: race.boots.first, witnesses: Set.of(race.forRemoval), removal: true));
      _remove(seat);
      _pause = null;
      _botActs(turn, seat, (holders[seat] as BotSeat).persona);
    } else if (race.forRemoval.isNotEmpty) {
      // Proposed, and not carried: is it ever going to be?
      final reachable = race.snapshot.difference({(holders[seat] as HumanSeat).key});
      if (reachable.length < needed) _pause = Pause.waitingForJury;
    }
  }

  void _remove(int seat) {
    final holder = holders[seat];
    if (holder is HumanSeat) {
      participants.remove(holder.key);
      _seatBot(seat);
    }
  }

  void _seatBot(int seat) {
    holders[seat] = BotSeat(spec.replacementFor(seat));
  }

  void _onLeave(TableEvent event) {
    final seat = event.seat;
    if (seat < 0 || seat >= seatCount) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key != event.author) return;
    if (event.hand > game.handNumber || (event.hand == game.handNumber && event.step > step)) {
      return _defer(event);
    }
    final open = _openTurnOf(seat);
    _log(Decision(turn: open ?? TurnId(game.handNumber, step), event: event, witnesses: {event.author}, removal: true));
    _remove(seat);
    if (open != null) {
      _races[open]!.settled = true;
      _botActs(open, seat, (holders[seat] as BotSeat).persona);
    }
    _repauseOrResume();
  }

  // ---- absence ------------------------------------------------------------

  void _onAbsent(TableEvent event) {
    final seat = event.seat;
    if (seat < 0 || seat >= seatCount) return;
    if (event.hand != game.handNumber) return;
    if (!participants.contains(event.author)) return;
    final holder = holders[seat];
    if (holder is! HumanSeat || holder.key == event.author) return;
    final a = _absences.putIfAbsent(seat, () => _Absence(snapshot: Set.of(participants)));
    a.claims.add(event);
    a.backers.add(event.author);
    if (_earlyWitnesses.containsKey(event.id)) {
      a.backers.addAll(_earlyWitnesses.remove(event.id)!);
    }
    // Countersign only when this peer has heard nothing from the seat
    // for as long itself.
    if (amSeated && !a.backers.contains(signer.publicKey) && _silent(holder.key)) {
      a.backers.add(signer.publicKey);
      final w = TableEvent.sign(signer, table: spec.id, kind: EventKind.witness, body: {
        'event': event.id,
        'hand': event.hand,
        'turn': -1,
        'seat': seat,
      });
      transport.broadcast(w.toJson());
      _seen.add(w.id);
    }
    _settleAbsence(a);
  }

  bool _silent(PublicKey key) => clock.nowMs - (_lastHeard[key] ?? clock.nowMs) >= silenceAfterMs;

  void _settleAbsence(_Absence a) {
    if (a.settled) return;
    final seat = a.claims.first.seat;
    final holder = holders[seat];
    if (holder is! HumanSeat) {
      a.settled = true;
      return;
    }
    final needed = a.snapshot.length ~/ 2 + 1;
    if (a.backers.intersection(a.snapshot).length >= needed) {
      a.settled = true;
      final open = _openTurnOf(seat);
      _log(Decision(
        turn: open ?? TurnId(game.handNumber, step),
        event: a.claims.first,
        witnesses: Set.of(a.backers),
        removal: true,
      ));
      _remove(seat);
      if (open != null) {
        _races[open]!.settled = true;
        _botActs(open, seat, (holders[seat] as BotSeat).persona);
      }
      _repauseOrResume();
    } else {
      final reachable = a.snapshot.difference({holder.key});
      _pause = reachable.length < needed ? Pause.waitingForJury : Pause.waitingForPeers;
    }
  }

  void _repauseOrResume() {
    _pause = null;
    for (final r in _races.values) {
      if (!r.settled && r.forRemoval.isNotEmpty) {
        _settle(_races.entries.firstWhere((e) => e.value == r).key);
      }
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

  /// Once a second: propose the removal of anyone silent too long, and
  /// re-check boots this peer held back on until its clock agreed.
  void _tick() {
    if (_closed) return;
    if (amSeated && !_left && !done) {
      for (var seat = 0; seat < seatCount; seat++) {
        final h = holders[seat];
        if (h is! HumanSeat || h.key == signer.publicKey || !participants.contains(h.key)) continue;
        if (_silent(h.key) && !_absences.containsKey(seat) && !_mySilenceClaims.containsKey(h.key)) {
          _mySilenceClaims[h.key] = clock.nowMs;
          _emit(EventKind.absent, {'hand': game.handNumber, 'step': step, 'seat': seat});
        }
      }
      for (final e in _races.entries) {
        final race = e.value;
        if (race.settled || race.boots.isEmpty || _myWitness.containsKey(e.key)) continue;
        _considerCountersigning(e.key, race.boots.first);
        _settle(e.key);
      }
      _absences.removeWhere((seat, a) => a.settled);
    }
    _notify();
    _timers.add(clock.schedule(1000, _tick));
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }
}

class _Race {
  _Race({required this.snapshot});

  /// The participants when the turn opened: who a majority is of.
  final Set<PublicKey> snapshot;

  TableEvent? action;
  final List<TableEvent> boots = [];
  final Set<PublicKey> forAction = {};
  final Set<PublicKey> forRemoval = {};
  bool settled = false;
}

class _Absence {
  _Absence({required this.snapshot});

  final Set<PublicKey> snapshot;
  final List<TableEvent> claims = [];
  final Set<PublicKey> backers = {};
  bool settled = false;
}
