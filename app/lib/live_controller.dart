/// Drives the table's widgets from a live table: a [TableClient] over
/// a real transport, with the protocol deciding whose turn it is and
/// what has settled. The engine is the client's; this adds what a view
/// needs — the pass selection, the score sheet of the hand just
/// finished, the buttons a live table has that a solo one does not —
/// and, above all, pace.
///
/// The client's game jumps: the moment a person's play settles, every
/// bot that follows plays at once, and a finished trick is swept in the
/// same instant. A person watching that sees their own card, two bots'
/// cards and the sweep land in one frame, if they see them at all. So
/// the view is fed a second game, replayed from the client's record at
/// a human pace — each bot thinks for its persona's beat, a finished
/// trick sits for a moment, another person's card lands a beat after
/// the last — exactly as the solo table paces itself. The replay is the
/// verifier's (record.dart): the record's passes and plays, with the
/// bots recomputed, so it can only ever show what the table agreed.
/// Meanwhile the player's own card goes on the table the instant it is
/// tapped, ahead of the settlement that will confirm it.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'table_model.dart';

class LiveController extends ChangeNotifier implements TableModel {
  LiveController({
    required TableSpec spec,
    required this.seatNames,
    required Signer signer,
    required Transport transport,
    Clock? clock,
    Presence? presence,
    this.ratingOf,
    this.onResult,
    this.paced = true,
  }) : client = TableClient(spec: spec, signer: signer, transport: transport, clock: clock ?? WallClock(), presence: presence) {
    _shown = HeartsGame(seed: spec.seed);
    _shownHolders = List.of(spec.seats);
    _sub = client.changes.listen((_) => _onChange());
    client.start();
  }

  final TableClient client;

  /// The humans' names by seat, from the lobby.
  final Map<int, String> seatNames;

  /// Ratings by key or persona id, on a rated table; null elsewhere.
  final Rating Function(String id)? ratingOf;

  /// Where a finished game's result goes, once, when the game ends.
  final void Function(GameResult result)? onResult;

  /// Whether the view is paced. Tests turn it off.
  final bool paced;

  bool _reported = false;
  StreamSubscription<void>? _sub;
  final Set<Card> _selected = {};

  /// The score sheet of the hand just finished, until dismissed.
  ({int hand, List<int> scores, List<int> totals, int? moonShooter})? handJustEnded;
  Timer? _sheetTimer;

  // ---- the paced view ---------------------------------------------------

  late HeartsGame _shown;
  late List<SeatHolder> _shownHolders;
  final Set<Card> _shownPlayed = {};

  /// The decisions of the client's record the view has shown, in order.
  final List<Decision> _consumed = [];

  /// The player's card on the table before its settlement, and their
  /// pass before its settlement.
  Card? _pendingPlay;
  Set<Card> _pendingPass = const {};

  bool _pumping = false;
  bool _disposed = false;
  final _rhythm = Random();
  int _lastCardAt = 0;

  static const _trickHold = Duration(milliseconds: 950);
  static const _cardBeat = Duration(milliseconds: 320);

  Duration _botThink(int seat) {
    final pace = (_shownHolders[seat] as BotSeat).persona.pace;
    return Duration(milliseconds: pace.minMs + _rhythm.nextInt(pace.maxMs - pace.minMs + 1));
  }

  /// Enough of a pause after the last card shown that two cards never
  /// land as one.
  Duration _beat() {
    final since = DateTime.now().millisecondsSinceEpoch - _lastCardAt;
    return since >= _cardBeat.inMilliseconds ? Duration.zero : Duration(milliseconds: _cardBeat.inMilliseconds - since);
  }

  void _onChange() {
    if (client.done && !_reported) {
      _reported = true;
      onResult?.call(GameResult.of(client.spec, client.holders, client.game.totals));
    }
    if (!client.awaitingMyPass) _selected.clear();
    unawaited(_pump());
    notifyListeners();
  }

  /// Whether the shown decisions are still the record's first ones —
  /// the record is kept in turn order, so a late decision about an
  /// earlier turn can land behind what has been shown.
  bool _inSync(List<Decision> record) {
    if (_consumed.length > record.length) return false;
    for (var i = 0; i < _consumed.length; i++) {
      if (!identical(record[i], _consumed[i])) return false;
    }
    return true;
  }

  /// Replays the whole record at once. A jump, for the rare case where
  /// the shown past was rewritten.
  void _rebuild(List<Decision> record) {
    _shown = HeartsGame(seed: client.spec.seed);
    _shownHolders = List.of(client.spec.seats);
    _shownPlayed.clear();
    _consumed.clear();
    for (var guard = 0; guard < 10000; guard++) {
      final step = _next(record);
      if (step == null) break;
      step.act();
    }
  }

  void _botActs(int seat, {required bool passing}) {
    final bot = Bot(persona: (_shownHolders[seat] as BotSeat).persona);
    if (passing) {
      _shown.setPass(seat, bot.choosePass(_shown.handOf(seat)));
    } else {
      final view = BotView(
        seat: seat,
        hand: _shown.handOf(seat),
        trick: _shown.trick,
        played: _shownPlayed,
        heartsBroken: _shown.heartsBroken,
        isFirstTrick: _shown.isFirstTrick,
        taken: _shown.taken,
      );
      final card = bot.chooseCard(view, _shown.legalPlaysFor(seat));
      _shown.play(seat, card);
      _shownPlayed.add(card);
      _lastCardAt = DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// The next thing the view should show, and how long to wait before
  /// showing it; null when the view is waiting on a person, or the
  /// game is over.
  ({Duration delay, void Function() act})? _next(List<Decision> record) {
    // Departures recorded next take effect at once.
    if (_consumed.length < record.length && record[_consumed.length].removal) {
      final d = record[_consumed.length];
      return (
        delay: Duration.zero,
        act: () {
          _consumed.add(d);
          final seat = d.event.seat;
          if (_shownHolders[seat] is HumanSeat) {
            _shownHolders[seat] = BotSeat(client.spec.replacementFor(seat));
            if (seat == mySeat) {
              _pendingPlay = null;
              _pendingPass = const {};
            }
          }
        }
      );
    }
    if (_shown.phase == Phase.passing) {
      for (var s = 0; s < seatCount; s++) {
        if (_shownHolders[s] is BotSeat && _shown.passOf(s) == null) {
          return (delay: Duration.zero, act: () => _botActs(s, passing: true));
        }
      }
      if (_consumed.length >= record.length) return null; // a person's pass is owed
      final d = record[_consumed.length];
      if (d.event.kind != EventKind.pass) return null; // not what the replay expects: leave it to a rebuild
      return (
        delay: Duration.zero,
        act: () {
          _consumed.add(d);
          _shown.setPass(d.event.seat, [for (final c in d.event.body['cards'] as List) Card.parse(c as String)]);
          if (d.event.seat == mySeat) _pendingPass = const {};
        }
      );
    }
    if (_shown.phase == Phase.gameOver) return null;
    if (_shown.pendingTrick != null) {
      return (
        delay: _trickHold,
        act: () {
          _shown.collectTrick();
          if (_shown.phase == Phase.handOver) {
            handJustEnded = (
              hand: _shown.handNumber,
              scores: _shown.handScores,
              totals: _shown.totals,
              moonShooter: _shown.moonShooter,
            );
            _sheetTimer?.cancel();
            _sheetTimer = Timer(const Duration(seconds: 6), dismissHandSheet);
            _shown.nextHand();
            _shownPlayed.clear();
          }
        }
      );
    }
    final seat = _shown.currentSeat!;
    if (_shownHolders[seat] is BotSeat) {
      return (delay: _botThink(seat), act: () => _botActs(seat, passing: false));
    }
    if (_consumed.length >= record.length) return null; // a person's play is owed
    final d = record[_consumed.length];
    if (d.event.kind != EventKind.play || d.event.seat != seat) return null;
    return (
      delay: seat == mySeat ? Duration.zero : _beat(),
      act: () {
        _consumed.add(d);
        final card = Card.parse(d.event.body['card'] as String);
        _shown.play(seat, card);
        _shownPlayed.add(card);
        _lastCardAt = DateTime.now().millisecondsSinceEpoch;
        if (seat == mySeat) _pendingPlay = null;
      }
    );
  }

  /// Advances the shown game as far as the record allows, at pace. One
  /// loop runs at a time; a change that arrives while it runs is picked
  /// up on its next step.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      var rebuilt = false;
      while (!_disposed) {
        final record = client.record;
        if (!_inSync(record)) {
          _rebuild(record);
          rebuilt = true;
          notifyListeners();
          continue;
        }
        final step = _next(record);
        if (step == null) {
          // Nothing to show — unless the record holds more than the
          // replay expects, which one rebuild settles.
          if (_consumed.length < record.length && !rebuilt) {
            _rebuild(record);
            rebuilt = true;
            notifyListeners();
            continue;
          }
          break;
        }
        if (paced && step.delay > Duration.zero) {
          await _wait(step.delay);
          if (_disposed) return;
          if (!_inSync(client.record)) continue; // the past changed while waiting
        }
        step.act();
        notifyListeners();
      }
    } finally {
      _pumping = false;
      if (!_disposed) notifyListeners();
    }
  }

  Timer? _waitTimer;

  /// A pause the controller can cancel: nothing outlives the widget.
  Future<void> _wait(Duration d) {
    final done = Completer<void>();
    _waitTimer?.cancel();
    _waitTimer = Timer(d, done.complete);
    return done.future;
  }

  /// Whether the view has shown everything the table has settled, so
  /// the player is looking at the position they are asked to play.
  bool get _caughtUp => !_pumping && _consumed.length == client.record.length;

  /// A seat's name with its rating: "Roxane 1520". The rating is the
  /// seat's as dealt — a bot that took over a leaver's seat shows the
  /// leaver's, since that is whose result it still is.
  String nameWithRating(int seat) {
    final r = ratingOf;
    if (r == null) return _plainName(seat);
    final id = switch (client.spec.seats[seat]) {
      HumanSeat(:final key) => key,
      BotSeat(:final persona) => persona.id,
    };
    return '${_plainName(seat)} ${r(id).shown}';
  }

  void dismissHandSheet() {
    _sheetTimer?.cancel();
    if (handJustEnded == null) return;
    handJustEnded = null;
    notifyListeners();
  }

  // ---- TableModel -------------------------------------------------------

  /// The game as shown: the client's, replayed at pace.
  @override
  HeartsGame get game => _shown;

  @override
  int get mySeat => client.mySeat ?? 0;

  @override
  int positionOf(int seat) => (seat - mySeat + seatCount) % seatCount;

  @override
  int seatAt(int position) => (position + mySeat) % seatCount;

  /// Names, and on a rated table each name with its rating.
  @override
  List<String> get names => [for (var s = 0; s < seatCount; s++) ratingOf == null ? _plainName(s) : nameWithRating(s)];

  String _plainName(int s) => s == client.mySeat
      ? 'You'
      : switch (_shownHolders[s]) {
          BotSeat(:final persona) => persona.name,
          _ => seatNames[s] ?? 'Seat ${s + 1}',
        };

  @override
  Persona? personaAt(int seat) => switch (_shownHolders[seat]) {
        BotSeat(:final persona) => persona,
        _ => null,
      };

  @override
  Set<Card> get playedThisHand => Set.unmodifiable(_shownPlayed);

  @override
  Set<Card> get selected => Set.unmodifiable(_selected);

  @override
  bool get awaitingPass =>
      client.awaitingMyPass && _shown.phase == Phase.passing && _shown.passOf(mySeat) == null && _pendingPass.isEmpty;

  @override
  bool get canConfirmPass => awaitingPass && _selected.length == passSize;

  @override
  bool get awaitingPlay => client.awaitingMyPlay && _caughtUp && _pendingPlay == null;

  @override
  Set<Card> get legalNow => awaitingPlay ? _shown.legalPlaysFor(mySeat).toSet() : const {};

  @override
  Card? get pendingPlay => _pendingPlay;

  @override
  Set<Card> get inFlight => {?_pendingPlay, ..._pendingPass};

  @override
  void toggleSelected(Card card) {
    if (!awaitingPass) return;
    if (!_selected.remove(card)) {
      if (_selected.length == passSize) return;
      _selected.add(card);
    }
    notifyListeners();
  }

  @override
  void confirmPass() {
    if (!canConfirmPass) return;
    final cards = _selected.toList();
    // Marked in flight before the client hears of it: at a table of one
    // person the pass settles inside the call, and the settlement is
    // what clears the mark.
    _pendingPass = cards.toSet();
    _selected.clear();
    client.pass(cards);
    notifyListeners();
  }

  @override
  String? playCard(Card card) {
    if (!awaitingPlay) return null;
    if (!_shown.legalPlaysFor(mySeat).contains(card)) return refusalFor(_shown, mySeat, card);
    // Pending before the client hears of it, for the same reason as the
    // pass: the settlement that clears it can come back synchronously.
    _pendingPlay = card;
    _lastCardAt = DateTime.now().millisecondsSinceEpoch;
    client.play(card);
    notifyListeners();
    return null;
  }

  // ---- what a live table has besides -----------------------------------

  bool get amSeated => client.amSeated;

  /// Over, as shown: the last trick has been seen.
  bool get done => _shown.phase == Phase.gameOver;
  TableState get tableState => client.tableState;
  Pause? get pause => client.pause;
  SeatState seatStateOf(int seat) => client.seatStateOf(seat);
  bool canBoot(int seat) => client.canBoot(seat);
  int? bootCountdownMs(int seat) => client.bootCountdownMs(seat);
  void boot(int seat) {
    client.boot(seat);
    notifyListeners();
  }

  void leave() {
    client.leave();
    notifyListeners();
  }

  /// Humans still at the table, by seat.
  int get participants => client.participants.length;

  /// The hand's jury: drawn and heard from.
  ({int drawn, int live}) get jury => client.jury;

  /// The table found nobody online to draw a jury from.
  bool get needsJuror => client.needsJuror;

  /// The record so far, as the verifier sees it.
  Verification verification() => verifyRecord(client.spec, client.record, allowPartial: !client.done, juries: client.juries);

  @override
  void dispose() {
    _disposed = true;
    _waitTimer?.cancel();
    _sheetTimer?.cancel();
    _sub?.cancel();
    client.close();
    super.dispose();
  }
}
