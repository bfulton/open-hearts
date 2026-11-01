/// Drives the table's widgets from a live table: a [TableClient] on the
/// referee's log (packages/table), with the rules deciding whose turn it
/// is and what the table did. The engine is the rules'; this adds what a
/// view needs — the pass selection, the score sheet of the hand just
/// finished, what a live table says besides — and, above all, pace.
///
/// The table jumps: two people's cards can land together, a full trick
/// is swept the moment its last card is in, a departed person's cards,
/// played by every side, come all at once. A person watching that sees
/// cards and the sweep land in one frame, if they see them at all. So
/// the rules hand the view the table after each change a person could
/// see (packages/table, rules.dart, `Frame`), and the view shows them
/// one at a time — a card a beat after the last, a finished trick held
/// for a moment. A bot's moment of thought is the house's, in the log
/// (packages/table, house.dart, `pace`), not the screen's: the player's
/// clock runs from when the log opens their turn, and the screen offers
/// it a beat or a trick's hold after. Nothing is worked out here, so it
/// can only ever show what the table did, a moment later; what came
/// while this device was catching up, after a reload or a dropped line,
/// is shown at once. Meanwhile the player's own card goes on the table
/// the instant it is tapped, ahead of the log that will carry it.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

import '../avatar.dart';
import '../l10n/l10n.dart';
import '../net/report_error.dart';
import '../pacing.dart';
import '../pictures.dart';
import '../reaction_mute.dart';
import '../table_model.dart';

class LiveController extends ChangeNotifier with TableModel {
  LiveController({
    required TableSpec spec,
    required this.seatNames,
    this.seatAvatars = const {},
    required Signer signer,
    required RefereeLine line,
    Clock? clock,
    DealCrypto? crypto,
    DealWorker? dealWorker,
    this.ratingOf,
    this.onResult,
    this.pictures,
    this.canPlayAgain = false,
    this.strangers = false,
    TableJournal? journal,
    Random? random,
    ReactionLane? reactions,
    int Function()? screenClock,
    void Function(String line)? trace,
  })  : _lane = reactions,
        _screenClock = screenClock ?? _wallMs,
        _trace = trace,
        _reactionRules = ReactionRules(now: screenClock),
        client = TableClient(
            tableId: spec.id,
            spec: spec,
            signer: signer,
            line: line,
            clock: clock ?? WallClock(),
            crypto: crypto,
            dealWorker: dealWorker,
            journal: journal,
            random: random,
            trace: trace) {
    _shown = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target);
    _shownHolders = List.of(spec.seats);
    // Once the seat is gone nothing more is shown ([_next]), so nothing
    // more is kept to show.
    client.rules.onFrame = (frame) {
      if (client.amSeated) _frames.add((frame: frame, paced: client.caughtUp));
    };
    _sub = client.changes.listen((_) => _onChange());
    pictures?.addListener(_pictured);
    _heardReactions = reactions?.reactions.listen(_heardReaction);
    _mute.addListener(_muteChanged);
    _downSince = client.clock.nowMs;
    _armDown();
    client.start();
  }

  final TableClient client;

  /// The table as this device was seated at it.
  TableSpec get spec => client.spec!;

  /// Why the referee turned this device away for good, if it did:
  /// another device of the account took it up, or the account was
  /// suspended (packages/table, relays.dart, `turnedAway`). A table cut
  /// off like that looks alive until it is said.
  String? get relayRefusal => client.line.refused;

  /// The humans' names by seat, from the lobby.
  final Map<int, String> seatNames;

  /// The humans' avatars by seat, from the lobby.
  final Map<int, Avatar> seatAvatars;

  /// Ratings by key or persona id, on a rated table; null elsewhere.
  final Rating Function(String id)? ratingOf;

  /// Where a finished game's result goes, once the house has said it:
  /// the device's own ledger, which folds it (net/standing.dart).
  final void Function(GameResult result)? onResult;

  /// What the game did to this player's rating, at a rated table:
  /// where it stood as the game ended, and where it stands with the
  /// result folded in. Null at an unrated table, on a seat this device
  /// does not hold, and while the new rating is not known — the game's
  /// sheet says nothing rather than guess at it.
  ({Rating before, Rating after})? ratingChange;

  /// What this device does with the others' pictures: hidden by the
  /// viewer, or kept off by its own check (pictures.dart). Null leaves
  /// every picture alone.
  final Pictures? pictures;

  /// Whether the lobby can start another game the same way (same pool
  /// or room). False for a table reopened after a reload, which has no
  /// `again` callback (lobby.dart).
  final bool canPlayAgain;

  /// Whether Play live seated this table, with strangers, rather than a
  /// friends' room: leaving its game early is waited out before Play
  /// live seats this device again (left_early.dart).
  final bool strangers;

  void _pictured() {
    if (_disposed) return;
    // A player blocked while their reaction shows: it goes now.
    for (final (seat, holder) in _shownHolders.indexed) {
      if (holder is HumanSeat && _blocked(holder.account)) _reacting.remove(seat)?.gone.cancel();
    }
    notifyListeners();
  }

  /// Whether the viewer blocked [account] (pictures.dart): its name,
  /// picture and reactions are not shown.
  bool _blocked(String account) => pictures?.isBlocked(account) ?? false;

  bool _reported = false;
  StreamSubscription<void>? _sub;
  final Set<Card> _selected = {};

  /// The score sheet of the hand just finished, until dismissed.
  ({int hand, List<int> scores, List<int> totals, int? moonShooter})? handJustEnded;
  Timer? _sheetTimer;

  // ---- the paced view ---------------------------------------------------

  late HeartsGame _shown;
  late List<SeatHolder> _shownHolders;
  Set<Card> _shownPlayed = const {};

  /// What the table has handed the view and it has not shown yet, each
  /// with whether this device was caught up with the log when it came:
  /// what came while it was not is shown without waiting.
  final Queue<({Frame frame, bool paced})> _frames = Queue();

  /// The player's card on the table before the log carries it, and
  /// their pass before the log carries it.
  Card? _pendingPlay;
  Set<Card> _pendingPass = const {};

  bool _pumping = false;
  bool _disposed = false;

  /// When the view last showed something, and last showed a card.
  int _shownAt = 0;
  int _lastCardAt = 0;

  /// How long after the card before any other seat's card is shown:
  /// the moment a card takes to land, so that two played at once are
  /// seen one after the other.
  static const cardBeat = Duration(milliseconds: 320);

  /// The screen's own clock, in milliseconds since the epoch: what the
  /// view's pace and the reactions' gaps go by, as its pauses are timers
  /// on it. Real time, but in a test whose timers keep a time of their
  /// own.
  final int Function() _screenClock;
  static int _wallMs() => DateTime.now().millisecondsSinceEpoch;

  int get _nowMs => _screenClock();

  final void Function(String line)? _trace;

  /// Timing of this player's current turn, for the debug trace: `since`
  /// is when the referee opened it (the referee's clock); `here` and
  /// `shown` are this device's wall-clock ms when the table first owed
  /// it and when the screen first offered it. Outside the browser
  /// suites the deltas include any skew between the two clocks.
  ({TurnId turn, int since, int here, int? shown})? _met;
  bool _metSaid = false;

  /// Says how long [_met] took to reach this device, its screen, and
  /// [what] it came to, once.
  void _traceMet(String what) {
    final m = _met;
    if (m == null || _metSaid) return;
    _metSaid = true;
    final now = _wallMs();
    _trace?.call('my ${m.turn}, opened at ${m.since}: here +${m.here - m.since}, '
        'shown ${m.shown == null ? 'never' : '+${m.shown! - m.since}'}, $what +${now - m.since} ms');
  }

  /// The game is over as shown, and its last trick has been seen off
  /// the table: the game's sheet may show.
  bool get gameOverDue => _gameOverDue;
  bool _gameOverDue = false;

  /// The last hand whose sheet has been raised on this screen, or that
  /// ended while this device was catching up and has none.
  int _sheetsShownThrough = -1;

  /// How long to wait before showing [f]: any other seat's card a beat
  /// after the last card; a full trick held a moment before it is swept;
  /// the bare felt of a hand given up. The player's own card, at once,
  /// and the rest as they come.
  Duration _before(Frame f) {
    final now = _nowMs;
    Duration after(Duration want, int since) {
      final left = want - Duration(milliseconds: now - since);
      return left > Duration.zero ? left : Duration.zero;
    }

    return switch (f.change) {
      FrameChange.played when f.seat == mySeat => Duration.zero,
      FrameChange.played => after(cardBeat, _lastCardAt),
      FrameChange.collected => after(Pacing.trickHold, _shownAt),
      FrameChange.givenUp => after(Pacing.sweepBeat, _shownAt),
      _ => Duration.zero,
    };
  }

  /// The table as the frame has it, on the screen.
  void _show(Frame f) {
    _shown = f.game;
    _shownHolders = List.of(f.holders);
    _shownPlayed = f.played;
    _shownAt = _nowMs;
    if (f.change == FrameChange.played) _lastCardAt = _shownAt;
    if (f.seat == mySeat && f.change == FrameChange.played) _pendingPlay = null;
    if (f.seat == mySeat && f.change == FrameChange.passed) _pendingPass = const {};
    // A new hand, or one given up: nothing of the last is in flight.
    if (f.change == FrameChange.nextHand || f.change == FrameChange.givenUp) {
      _pendingPlay = null;
      _pendingPass = const {};
    }
  }

  /// The hand shown out to its sheet. The next one is dealt under it,
  /// as the table has it.
  void _sheet() {
    final g = _shown;
    _sheetsShownThrough = g.handNumber;
    handJustEnded = (hand: g.handNumber, scores: g.handScores, totals: g.totals, moonShooter: g.moonShooter);
    _sheetTimer?.cancel();
    _sheetTimer = Timer(const Duration(seconds: 6) * tableBeats, dismissHandSheet);
  }

  /// The next thing the view should show, and how long to wait before
  /// showing it; null when there is nothing yet.
  ({Duration delay, void Function() act})? _next() {
    // Once this device's seat is gone the shown game stops. The page
    // draws the notice rather than the table, and the table plays the
    // player's hand out without them; this screen does not follow it.
    if (!client.amSeated) return null;
    final shown = _shown;
    final next = _frames.firstOrNull;
    // A hand over as shown: the beat of bare felt that ends any hand,
    // then its sheet. A hand that ended while this device was catching
    // up is over and done with: no sheet for it now.
    if (shown.phase == Phase.handOver && shown.handNumber > _sheetsShownThrough) {
      if (next != null && !next.paced) return (delay: Duration.zero, act: () => _sheetsShownThrough = shown.handNumber);
      return (delay: Pacing.sweepBeat, act: _sheet);
    }
    // The game over as shown: the same beat, then its sheet.
    if (shown.phase == Phase.gameOver) {
      if (_gameOverDue) return null;
      return (delay: Pacing.sweepBeat, act: () => _gameOverDue = true);
    }
    if (next == null) return null;
    return (delay: next.paced ? _before(next.frame) : Duration.zero, act: () => _show(_frames.removeFirst().frame));
  }

  /// Advances the shown game as far as the table has gone, at pace. One
  /// loop runs at a time; a frame that arrives while it runs is picked
  /// up on its next step.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed) {
        final step = _next();
        if (step == null) break;
        if (step.delay > Duration.zero) {
          await _wait(step.delay);
          if (_disposed) return;
        }
        step.act();
        notifyListeners();
      }
    } finally {
      _pumping = false;
      if (!_disposed) {
        notifyListeners();
        _autoPlay();
      }
    }
  }

  Timer? _waitTimer;

  /// A pause the controller can cancel: nothing outlives the widget.
  Future<void> _wait(Duration d) {
    final done = Completer<void>();
    _waitTimer?.cancel();
    _waitTimer = Timer(d * tableBeats, done.complete);
    return done.future;
  }

  /// Whether the view has shown everything the table has done, so the
  /// player is looking at the position they are asked to play.
  bool get _caughtUp => !_pumping && _frames.isEmpty;

  /// What the screen is waiting on, for the debug line a driven build
  /// carries (live/live_page.dart). A table stuck from the outside is
  /// often a screen that has not caught up with it.
  String get behind => 'shown ${_shown.phase.name} h${_shown.handNumber}; ${_frames.length} frames to show; '
      'pumping $_pumping; pending ${_pendingPlay?.code ?? '-'}/${_pendingPass.length}';

  // ---- the table changed ------------------------------------------------

  void _onChange() {
    final mine = client.myTurn;
    if (mine != null && mine.turn != _met?.turn) {
      _met = (turn: mine.turn, since: mine.since, here: _wallMs(), shown: null);
      _metSaid = false;
    }
    if (!client.amSeated) _traceMet('seat gone');
    _watchLine();
    _beatClocks();
    final result = client.rules.result;
    if (result != null && !_reported) {
      _reported = true;
      final r = GameResult.ofTable(client.rules);
      if (r != null) _report(r);
    }
    if (!client.awaitingMyPass) _selected.clear();
    unawaited(_pump());
    notifyListeners();
  }

  /// The house's word on the finished game, folded where it goes, and
  /// what it did to this player's rating on the way: the ratings are
  /// read either side of the fold, which is arithmetic this device does
  /// itself. A rating that has not moved is one nobody has folded yet.
  void _report(GameResult result) {
    final rating = ratingOf;
    final holder = spec.seats[mySeat];
    // A rating is the account's, whichever of its devices played.
    final account = holder is HumanSeat ? holder.account : null;
    if (rating == null || account == null) {
      onResult?.call(result);
      return;
    }
    final before = rating(account);
    onResult?.call(result);
    final after = rating(account);
    if (after.mu != before.mu) ratingChange = (before: before, after: after);
  }

  /// A second's beat while a person's turn is open at the table: the
  /// table's entries come only when something happens, and a clock
  /// counts down on the screen between them (clockMs).
  Timer? _clockBeat;

  void _beatClocks() {
    final r = client.rules;
    final running = client.started &&
        !client.done &&
        r.owed.values.any((o) => (o.turn.isPass || o.turn.isPlay) && r.holders[o.seat] is HumanSeat);
    if (!running) {
      _clockBeat?.cancel();
      _clockBeat = null;
    } else {
      _clockBeat ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_disposed) notifyListeners();
      });
    }
  }

  // ---- this device's line ------------------------------------------------

  /// The line in a few words, for a report of it ([RelayLine.health]).
  String get _lineHealth {
    final line = client.line;
    return line is RelayLine ? line.health : '';
  }

  /// When this device's line to the referee went down, or null while it
  /// is up. Set at construction, so the time before the first connect
  /// counts as down. [_wasUp] is whether the line has been up since the
  /// table opened.
  int? _downSince;
  bool _wasUp = false;
  Cancel? _downTimer;
  bool _toldLost = false, _toldDown = false, _toldCannotDeal = false;

  /// How long a line that was up may be down before it is said: a
  /// socket made again takes a moment, and that is not news. A table's
  /// line that has never been up is given as long as an unanswered one
  /// is ([unansweredMs]): it opens a moment after the table does.
  static const downSaidAfterMs = 3000;

  /// How long a line may be down at a live table before it is told of:
  /// past anything a train's tunnel or a lift does, and well short of
  /// the minutes a player waits before giving up.
  static const downTooLongMs = 2 * 60 * 1000;

  int get _downSaidAfter => _wasUp ? downSaidAfterMs : unansweredMs;

  /// Whether to say this device's own line is down.
  bool get lineDown {
    final since = _downSince;
    return since != null && client.lineDown && client.clock.nowMs - since >= _downSaidAfter;
  }

  /// Tells the operator of a game lost — the house let a turn run out —
  /// of a deal this device could no longer run, and of a line down for
  /// [downTooLongMs]: each once a table, and with what the device saw of
  /// it (report_error.dart, reportLine).
  void _watchLine() {
    if (client.state == TableState.failed && !_toldLost) {
      _toldLost = true;
      reportLine('game lost: the house let a turn run out', table: spec.id, seen: _seen, line: _lineHealth);
    }
    final cannotDeal = client.cannotDeal;
    if (cannotDeal != null && !_toldCannotDeal) {
      _toldCannotDeal = true;
      reportLine('cannot deal: $cannotDeal', table: spec.id, seen: _seen, line: _lineHealth);
    }
    if (!client.lineDown) {
      _wasUp = true;
      _downSince = null;
      _downTimer?.call();
      _downTimer = null;
      return;
    }
    if (_downSince != null) return;
    _downSince = client.clock.nowMs;
    _armDown();
  }

  /// Where the table stands as this device saw it, for a report of a
  /// game lost or a line down: the log's length and the hand, what was
  /// owed and whether its actor's line was down, and this device's own.
  /// No key, card or name.
  String get _seen {
    final r = client.rules;
    final owed = [for (final o in r.owed.values) '${o.turn} seat ${o.seat}${r.down.containsKey(o.actor) ? ' (down)' : ''}'];
    final hand = r.spec == null ? '' : ', hand ${r.game.handNumber} ${r.game.phase.name}';
    return '${r.state.name} at #${r.log.length}$hand; owed ${owed.isEmpty ? 'nothing' : owed.join(', ')}; '
        '${r.down.length} down; line ${client.lineDown ? 'down' : 'up'}';
  }

  /// The moments a line down is said, and is told of.
  void _armDown() {
    final since = _downSince;
    if (since == null || _disposed) return;
    final now = client.clock.nowMs;
    final sayAt = since + _downSaidAfter;
    final at = now < sayAt ? sayAt : (_toldDown ? null : since + downTooLongMs);
    _downTimer?.call();
    _downTimer = null;
    if (at == null) return;
    _downTimer = client.clock.schedule(max(0, at - now), () {
      _downTimer = null;
      final since = _downSince;
      if (_disposed || since == null) return;
      if (!_toldDown && client.clock.nowMs - since >= downTooLongMs && client.lineDown) {
        _toldDown = true;
        reportLine('line down ${(client.clock.nowMs - since) ~/ 1000} s', table: spec.id, seen: _seen, line: _lineHealth);
      }
      notifyListeners();
      _armDown();
    });
  }

  // ---- the Auto switch ---------------------------------------------------

  final AutoPilot _auto = AutoPilot();

  @override
  bool get autoOffered => _auto.offered(this);

  @override
  bool get autoPlay => _auto.on;

  @override
  void setAutoPlay(bool on) {
    _auto.set(this, on);
    notifyListeners();
    _autoPlay();
  }

  /// The player's turn, played for them when the switch is on: their
  /// own play, sent as any tap sends it. Only once the screen has
  /// caught up with the table ([awaitingPlay]); and once, since the
  /// table's client counts the turn said from the moment the card is
  /// sent (packages/table, client.dart).
  void _autoPlay() {
    if (_disposed) return;
    _auto.watch(this);
    final card = _auto.cardFor(this);
    if (card != null) _play(card, timed: false);
  }

  /// Every change the table shows is one the switch may be offered on,
  /// and one the player's own clock over a card may start at.
  @override
  void notifyListeners() {
    _auto.watch(this);
    _offeredAt = awaitingPlay ? (_offeredAt ?? _nowMs) : null;
    final m = _met;
    if (m != null && m.shown == null && (awaitingPlay || awaitingPass)) _met = (turn: m.turn, since: m.since, here: m.here, shown: _wallMs());
    super.notifyListeners();
  }

  // ---- this player's pace -------------------------------------------------

  /// When the screen offered the player the card they owe now.
  int? _offeredAt;

  /// How long the player took over each of their own cards, in order:
  /// from the moment the screen offered the play to the tap. Cards the
  /// Auto switch played are not theirs to time. Nobody else's business
  /// and in no signed record (packages/table, pace.dart).
  final List<int> myCardMs = [];

  /// A seat's name with its [rating]: "Roxane 1520". The rating is the
  /// seat's as dealt — a bot that took over a leaver's seat shows the
  /// leaver's, since that is whose result it still is.
  String _nameWithRating(int seat, Rating Function(String id) rating) {
    final id = switch (spec.seats[seat]) {
      HumanSeat(:final account) => account,
      BotSeat(:final persona) => persona.id,
    };
    return '${_plainName(seat)} ${rating(id).shown}';
  }

  void dismissHandSheet() {
    _sheetTimer?.cancel();
    if (handJustEnded == null) return;
    handJustEnded = null;
    notifyListeners();
  }

  // ---- TableModel -------------------------------------------------------

  /// The game as shown: the table's, a moment behind it, at pace.
  @override
  HeartsGame get game => _shown;

  @override
  int get mySeat => client.mySeat ?? 0;

  /// Names, and on a rated table each name with its rating.
  @override
  List<String> get names {
    final rating = ratingOf;
    return [for (var s = 0; s < seatCount; s++) rating == null ? _plainName(s) : _nameWithRating(s, rating)];
  }

  /// The words the table speaks in: the page sets them from the app's
  /// language (l10n/l10n.dart), and they are English until it does.
  AppLocalizations words = english;

  String _plainName(int s) => s == client.mySeat
      ? words.you
      : switch (_shownHolders[s]) {
          BotSeat(:final persona) => persona.name,
          HumanSeat(:final account) when _blocked(account) => words.blockedPlayer,
          _ => seatNames[s] ?? words.seatNumber(s + 1),
        };

  @override
  Persona? personaAt(int seat) => switch (_shownHolders[seat]) {
        BotSeat(:final persona) => persona,
        _ => null,
      };

  @override
  Set<Card> get playedThisHand => _shownPlayed;

  @override
  Set<Card> get selected => Set.unmodifiable(_selected);

  /// The player's pass is owed, and the screen shows the hand it is
  /// owed in. Others' passes still to be shown do not hold it up.
  @override
  bool get awaitingPass =>
      client.awaitingMyPass &&
      _shown.handNumber == client.game.handNumber &&
      _shown.phase == Phase.passing &&
      !_shown.hasPassed(mySeat);

  @override
  bool get canConfirmPass => awaitingPass && _selected.length == passSize;

  @override
  bool get awaitingPlay => client.awaitingMyPlay && _caughtUp && _shown.currentSeat == mySeat;

  @override
  Set<Card> get legalNow => awaitingPlay ? _shown.legalPlaysFor(mySeat).toSet() : const {};

  @override
  Card? get pendingPlay => _pendingPlay;

  @override
  Set<Card> get inFlight => {?_pendingPlay, ..._pendingPass};

  @override
  Set<Card> get passed {
    if (_pendingPass.isNotEmpty) return _pendingPass;
    if (_shown.phase == Phase.passing && _shown.hasPassed(mySeat)) return (_shown.passOf(mySeat) ?? const []).toSet();
    return const {};
  }

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
    // Marked in flight before the client hears of it: the log carries
    // it back, and its frame is what clears the mark.
    _pendingPass = cards.toSet();
    _selected.clear();
    _traceMet('passed');
    client.pass(cards);
    notifyListeners();
  }

  @override
  String? playCard(Card card) => _play(card, timed: true);

  String? _play(Card card, {required bool timed}) {
    if (!awaitingPlay) return null;
    if (!_shown.legalPlaysFor(mySeat).contains(card)) return refusalFor(_shown, mySeat, card, words);
    final offered = _offeredAt;
    if (timed && offered != null) myCardMs.add(_nowMs - offered);
    // Pending before the client hears of it, for the same reason as the
    // pass.
    _pendingPlay = card;
    _lastCardAt = _nowMs;
    _traceMet('played');
    client.play(card);
    notifyListeners();
    return null;
  }

  // ---- what a live table has besides -----------------------------------

  bool get amSeated => client.amSeated;

  /// Over, as shown: the last trick has been seen.
  bool get done => _shown.phase == Phase.gameOver;
  TableState get tableState => client.state;

  /// The game cannot go on: a turn of the house's ran out — the
  /// operator's service stopped answering, and nobody else can play a
  /// bot seat's cards. Nobody is rated on it.
  bool get failed => client.state == TableState.failed;

  /// Every clock stopped while a departed person's hand is opened from
  /// the escrow (docs/explanation/fair-deal.md).
  bool get openingHand => client.started && client.rules.paused;

  /// The table waits on somebody whose line to it is down: a turn owed
  /// by another person, or by the house, not connected now. It goes on
  /// when they are back, or when the table gives up on them.
  bool get waitingOnSomeoneDown {
    if (!client.started) return false;
    final r = client.rules;
    return r.owed.values.any((o) => o.actor != client.signer.publicKey && r.down.containsKey(o.actor));
  }

  @override
  int? clockMs(int seat) => client.clockMs(seat);

  @override
  String iconSeedOf(int seat) => switch (_shownHolders[seat]) {
        HumanSeat(:final account) => account,
        BotSeat(:final persona) => persona.name,
      };

  /// The player's own seat is labelled You, and wears the initials of
  /// the name it is seated under.
  @override
  String iconNameOf(int seat) => seat == client.mySeat ? (seatNames[seat] ?? names[seat]) : names[seat];

  @override
  Avatar avatarOf(int seat) => switch (_shownHolders[seat]) {
        HumanSeat(:final account) => _asShown(account, seatAvatars[seat] ?? Avatar.none),
        BotSeat(:final persona) => Avatar.forBot(persona.name),
      };

  /// The avatar as this device will draw it: the icon and the colour
  /// they chose, and their picture only if it is allowed here — kept
  /// off by the account, whichever of its devices it comes from.
  Avatar _asShown(String key, Avatar avatar) {
    final picture = avatar.picture;
    final pictures = this.pictures;
    if (picture == null || pictures == null) return avatar;
    return pictures.allows(key, picture) ? avatar : avatar.copyWith(clearPicture: true);
  }

  /// Who holds [seat], for the sheet holding their badge opens: their
  /// account, their name and the picture they chose, as they chose
  /// them, whether this device blocked them, and whether it hides their
  /// picture — by the viewer's choice, or the check's. Null for a bot
  /// and for your own seat.
  ({String key, String name, Uint8List? picture, bool blocked, bool hidden, bool flagged})? playerAt(int seat) {
    final holder = _shownHolders[seat];
    if (holder is! HumanSeat || seat == mySeat) return null;
    final picture = (seatAvatars[seat] ?? Avatar.none).picture;
    final pictures = this.pictures;
    return (
      key: holder.account,
      name: seatNames[seat] ?? words.seatNumber(seat + 1),
      picture: picture,
      blocked: _blocked(holder.account),
      hidden: picture != null && pictures != null && pictures.isHidden(holder.account),
      flagged: picture != null && pictures != null && pictures.wasFlagged(holder.account, picture),
    );
  }

  /// How long the line is kept open after a leave is said. The leaving
  /// is an event like any other and has to reach the referee, and the
  /// line it goes on is this one — so it is closed a beat later rather
  /// than under its own event.
  static const leaveBeat = Duration(milliseconds: 600);
  bool _left = false;

  /// Whether the player left the table by their own word. Unlike
  /// [TableClient.left], not set when the client leaves by itself
  /// because this device cannot deal.
  bool get left => _left;

  /// Seated in a game still going: leaving now gives the seat to a bot
  /// for good.
  bool get inGame => amSeated && !done && !failed;

  /// Called once, as the table's page goes, however it went: by a way
  /// out of its own, or by a browser's Back (router.dart), which
  /// completes nothing the front door could wait on (lobby.dart).
  VoidCallback? onClosed;

  void leave() {
    _walkingOut = othersPlaying;
    _left = true;
    client.leave();
    notifyListeners();
  }

  /// Whether somebody besides this device still sits at the table: a
  /// seat of a person, not of a bot.
  bool get othersSeated {
    for (var s = 0; s < seatCount; s++) {
      if (s != client.mySeat && client.holders[s] is HumanSeat) return true;
    }
    return false;
  }

  /// Whether leaving now would leave other people's game: one still
  /// going, with somebody else still seated. Leaving a game that is
  /// over, that cannot go on, or that nobody else is in, costs nobody
  /// anything. Over by the table's account, not the screen's, which
  /// plays the last trick out after.
  bool get othersPlaying => client.state == TableState.playing && othersSeated;

  /// [othersPlaying], as it was when this device left.
  bool _walkingOut = false;

  /// Whether this device left this game early, at a table Play live
  /// seated it at (left_early.dart): it left while others were playing,
  /// or the table gave its seat to a bot — its clock ran out, or it went
  /// quiet — with somebody else still seated and the game not over.
  /// Not when the game failed for everyone, nor when this device could
  /// no longer run the deal: neither is the player's doing.
  bool get leftEarly {
    if (!strangers) return false;
    if (_left) return _walkingOut;
    final c = client;
    return c.mySeat != null && !c.amSeated && c.state == TableState.playing && c.cannotDeal == null && othersSeated;
  }

  /// People still seated whose line to the table is open, this device
  /// included.
  int get here {
    final down = client.started ? client.rules.down : const <PublicKey, int>{};
    return [
      for (final h in client.holders)
        if (h is HumanSeat && (h.key == client.signer.publicKey || !down.containsKey(h.key))) h,
    ].length;
  }

  /// What the deal is doing, while the table deals; null otherwise.
  String? get dealNote {
    if (client.game.phase != Phase.dealing) return null;
    // This hand's: the last hand's deal stays the one the table has
    // until the next is begun.
    final d = client.dealOf(client.game.handNumber);
    if (d == null) return words.dealing;
    return switch (d.phase) {
      DealPhase.keys => words.dealingKeys,
      DealPhase.shuffles => words.shuffling((d.nextShuffler ?? 3) + 1),
      DealPhase.tokens => words.dealingTheCards,
      DealPhase.declare => words.openingTheCards,
      _ => words.dealing,
    };
  }

  // ---- reactions ---------------------------------------------------------
  // A seated player's 👍, shown for a moment beside their badge here and
  // on every other screen at the table and watching it (packages/table,
  // reactions.dart). Nothing of it reaches the client: it is said on a
  // lane of its own, beside the table's log and never in it, so no turn
  // or clock can be moved by one.

  /// Where this table's reactions are said and heard; null where there
  /// are none.
  final ReactionLane? _lane;
  final ReactionRules _reactionRules;
  StreamSubscription<HeardReaction>? _heardReactions;

  /// Whether this device hides the others' reactions (reaction_mute.dart).
  final ValueListenable<bool> _mute = ReactionMute.current;

  /// What is showing at each seat, and when it goes.
  final Map<int, ({SeatReaction shown, Timer gone})> _reacting = {};
  int _reactions = 0;

  /// Whether this player may react: seated in person at a table that
  /// carries reactions, and the seat not given up — which a device the
  /// account was taken up from has done (live/live_page.dart), so only
  /// the device in use says one. Through to the last trick: a good game
  /// is said as it ends.
  bool get canReact => _lane != null && client.amSeated && !_left;

  /// Says [reaction] for this player, and shows it beside their badge:
  /// at most one every [ReactionRules.gap], and nothing in between.
  void react(Reaction reaction) {
    final seat = client.mySeat;
    if (!canReact || seat == null) return;
    // The moment it is about, as this screen shows it: the hand, and how
    // many of its cards have been seen played.
    final content = _reactionRules.say(reaction, hand: _shown.handNumber, turn: _shownPlayed.length);
    if (content == null) return;
    _lane!.sayReaction(content);
    _showReaction(seat, reaction);
  }

  /// Somebody else's, as it arrives: shown if it is a reaction from a
  /// seat held in person here now, by the device holding it, about this
  /// hand or the one either side, lately, and not too soon after their
  /// last. A bot's seat has no key to say one with.
  void _heardReaction(HeardReaction heard) {
    if (_disposed) return;
    // A blocked player's reactions are not heard.
    final seated = {
      for (final (seat, holder) in client.holders.indexed)
        if (holder is HumanSeat && seat != client.mySeat && !_blocked(holder.account)) holder.key: seat,
    };
    final shown = _reactionRules.hear(heard, seated: seated, hand: client.game.handNumber);
    if (shown != null) _showReaction(shown.seat, shown.reaction);
  }

  void _showReaction(int seat, Reaction reaction) {
    _reacting.remove(seat)?.gone.cancel();
    _reacting[seat] = (
      shown: (reaction: reaction, n: ++_reactions),
      gone: Timer(ReactionRules.shownFor, () {
        _reacting.remove(seat);
        if (!_disposed) notifyListeners();
      }),
    );
    notifyListeners();
  }

  void _muteChanged() {
    if (!_disposed) notifyListeners();
  }

  /// Muted, nobody else's: this player's own still shows, since it is
  /// what they did.
  @override
  SeatReaction? reactionAt(int seat) {
    final shown = _reacting[seat]?.shown;
    if (shown == null || (seat != client.mySeat && _mute.value)) return null;
    return shown;
  }

  @override
  String nameAlone(int seat) => _plainName(seat);

  @override
  void dispose() {
    _disposed = true;
    onClosed?.call();
    onClosed = null;
    client.rules.onFrame = null;
    _waitTimer?.cancel();
    _sheetTimer?.cancel();
    _clockBeat?.cancel();
    _downTimer?.call();
    _sub?.cancel();
    _heardReactions?.cancel();
    _mute.removeListener(_muteChanged);
    for (final r in _reacting.values) {
      r.gone.cancel();
    }
    pictures?.removeListener(_pictured);
    // Nothing here reacts to the table any more, whichever way this
    // goes; only the line waits, and only for a leave that is still on
    // its way out. Waiting before the page is gone would be the player
    // standing at a table they have left.
    if (_left) {
      Timer(leaveBeat, client.close);
    } else {
      client.close();
    }
    super.dispose();
  }
}
