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

import 'package:deal/deal.dart';
import 'package:flutter/foundation.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'avatar.dart';
import 'l10n/l10n.dart';
import 'pictures.dart';
import 'table_model.dart';

class LiveController extends ChangeNotifier implements TableModel {
  LiveController({
    required TableSpec spec,
    required this.seatNames,
    this.seatAvatars = const {},
    required Signer signer,
    required Transport transport,
    RelayTransport? relay,
    Clock? clock,
    Presence? presence,
    DealCrypto? crypto,
    DealWorker? dealWorker,
    this.ratingOf,
    this.onResult,
    this.pictures,
    this.paced = true,
  })  : _crypto = crypto,
        client = TableClient(
            spec: spec,
            signer: signer,
            transport: transport,
            clock: clock ?? WallClock(),
            presence: presence,
            crypto: crypto,
            dealWorker: dealWorker) {
    _shown = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target);
    _shownHolders = List.of(spec.seats);
    _sub = client.changes.listen((_) => _onChange());
    pictures?.addListener(_pictured);
    _refusals = relay?.refusals.listen((reason) {
      relayRefusal = reason;
      // A device whose events no relay will take does not get to say
      // anyone else is absent (client.dart).
      client.writesRefused = reason != null;
      if (!_disposed) notifyListeners();
    });
    client.start();
  }

  final TableClient client;

  /// The reason the relays gave when every one of them refused this
  /// device's latest event; null while one takes them. A table cut
  /// off from the relays looks alive until it is said.
  String? relayRefusal;
  StreamSubscription<String?>? _refusals;

  /// The deal's primitives, at a sealed table; for the verifier.
  final DealCrypto? _crypto;

  /// The humans' names by seat, from the lobby.
  final Map<int, String> seatNames;

  /// The humans' avatars by seat, from the lobby.
  final Map<int, Avatar> seatAvatars;

  /// Ratings by key or persona id, on a rated table; null elsewhere.
  final Rating Function(String id)? ratingOf;

  /// Where a finished game's result goes, once, when the game ends.
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

  /// Whether the view is paced. Tests turn it off.
  final bool paced;

  void _pictured() {
    if (!_disposed) notifyListeners();
  }

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

  /// After the last trick of a hand is swept, a beat of bare felt
  /// before the sheet, as at the solo table: the cards fade out as
  /// every trick's do, and the hand is seen to end rather than cut.
  static const sweepBeat = Duration(milliseconds: 1200);

  /// The game is over as shown, and its last trick has been seen off
  /// the table: the game's sheet may show.
  bool get gameOverDue => _gameOverDue;
  bool _gameOverDue = false;

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
      _report(GameResult.of(client.spec, client.holders, client.game.totals));
    }
    if (!client.awaitingMyPass) _selected.clear();
    unawaited(_pump());
    notifyListeners();
  }

  /// The finished game out to whoever publishes it, and what it did to
  /// this player's rating on the way: the ratings are read either side
  /// of the report, since folding a result into the ledger is
  /// arithmetic this device does itself and nothing here may wait on a
  /// relay. A rating that has not moved is one nobody has folded yet.
  void _report(GameResult result) {
    final rating = ratingOf;
    final seat = client.mySeat;
    final holder = seat == null ? null : client.spec.seats[seat];
    final key = holder is HumanSeat ? holder.key : null;
    if (rating == null || key == null) {
      onResult?.call(result);
      return;
    }
    final before = rating(key);
    onResult?.call(result);
    final after = rating(key);
    if (after.mu != before.mu) ratingChange = (before: before, after: after);
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

  /// The last hand whose sheet has been raised on this screen.
  /// Whether the record has left behind the hand the view is still
  /// showing: nothing of it remains, and what comes next is a later
  /// hand's. That is a hand the table gave up where it stood
  /// (docs/03-fair-deal.md) — nobody could lead it, or a pass into a
  /// seat would never open — and there is nothing more of it to show.
  ///
  /// Asked only where the view has run out of things to do of its own:
  /// a bot's move is not in the record, so a hand that ends on three of
  /// them has nothing left in the record either, and is not given up.
  bool _givenUp(List<Decision> record) =>
      _consumed.length < record.length && record[_consumed.length].turn.hand > _shown.handNumber;

  /// A deal the view cannot show yet: it waits for the table to have
  /// the hand and its lead. Unless the table gave the hand up before
  /// either came — its deal abandoned when a held seat's juror could
  /// not take its step, or the hand opened and given up when nobody
  /// could lead it (the table's hand states, packages/table
  /// model.dart). That deal will never be shown, and the record has
  /// moved on to the next hand's pass, which a view still waiting here
  /// would never offer.
  ({Duration delay, void Function() act})? _dealNotShown(int hand) => switch (client.handOutcome(hand)) {
        HandState.abandoned || HandState.givenUp => (delay: sweepBeat, act: _giveUpShownHand),
        _ => null,
      };

  /// A hand given up, as the view shows it: the beat of bare felt that
  /// ends any hand, and then the next one dealt. No sheet — nothing was
  /// scored, because no hand happened.
  void _giveUpShownHand() {
    _shown.abandonHand();
    _shownPlayed.clear();
    _pendingPlay = null;
    _pendingPass = const {};
  }

  int _sheetsShownThrough = -1;

  /// The hand shown out to its sheet, and the next one begun under it.
  ///
  /// A hand's sheet shows once: a rebuild replays hands the player has
  /// already watched end, and a hand does not end twice. A rebuild that
  /// lands on a hand whose end was never shown still shows it.
  void _endOfHand() {
    final hand = _shown.handNumber;
    if (hand > _sheetsShownThrough) {
      _sheetsShownThrough = hand;
      handJustEnded = (hand: hand, scores: _shown.handScores, totals: _shown.totals, moonShooter: _shown.moonShooter);
      _sheetTimer?.cancel();
      _sheetTimer = Timer(const Duration(seconds: 6), dismissHandSheet);
    }
    _shown.nextHand();
    _shownPlayed.clear();
  }

  /// Replays the whole record at once. A jump, for the rare case where
  /// the shown past was rewritten.
  void _rebuild(List<Decision> record) {
    _shown = HeartsGame(seed: client.spec.seed, sealed: client.spec.sealed, target: client.spec.target);
    _shownHolders = List.of(client.spec.seats);
    _shownPlayed.clear();
    _consumed.clear();
    for (var guard = 0; guard < 10000; guard++) {
      final step = _next(record);
      if (step == null) break;
      step.act();
    }
  }

  /// Whether this view has to work a seat's move out for itself. A bot
  /// seat is everyone's to compute — unless a juror holds it, and then
  /// its move arrives as a signed event like a person's and its hand
  /// is not ours to see at all (docs/04-live-play.md, "Playing a seat
  /// nobody holds"). Asked of the hand being shown, which runs behind
  /// the table's: a seat can be a person's in the hand on screen and a
  /// bot the jury holds in the one the table is already dealing.
  bool _worksOutMove(int seat) =>
      _shownHolders[seat] is BotSeat && !client.botHolders(_shown.handNumber).containsKey(seat);

  /// A bot seat's hand, for the shown game to compute its move: dealt
  /// open, or a departed person's opened from escrow since. False
  /// while it is still closed.
  bool _seesHand(int seat) {
    if (_shown.knowsHand(seat)) return true;
    final deal = client.dealOf(_shown.handNumber);
    if (deal == null) return false;
    // As the shown game holds it: dealt while its pass is unresolved;
    // during its play, what the seat holds at the table plus whatever
    // it has played there that this view has yet to show — the shown
    // game runs behind the table.
    final List<int>? cards;
    if (_shown.phase == Phase.playing) {
      final held = deal.handOf(seat);
      cards = held == null ? null : [...held, for (final c in deal.playedCardsOf(seat)) if (!_shownPlayed.contains(Card.deck[c])) c];
    } else {
      cards = deal.dealtHandOf(seat);
    }
    if (cards == null) return false;
    _shown.revealHand(seat, [for (final i in cards) Card.deck[i]]);
    return true;
  }

  void _botActs(int seat, {required bool passing}) {
    final bot = Bot(persona: (_shownHolders[seat] as BotSeat).persona);
    if (passing) {
      _declareLead();
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

  /// Tells the shown game who leads, from where the deal has the 2♣.
  void _declareLead() {
    final leader = client.dealOf(_shown.handNumber)?.leader;
    if (leader != null && (_shown.phase == Phase.dealing || _shown.phase == Phase.passing)) _shown.declareLeader(leader);
  }

  /// The cards of a settled pass, as this side can see them: from the
  /// event at a seeded table; at a sealed one from the deal, which
  /// opened them when they are this side's own, a bot's, or a departed
  /// seat's — null otherwise.
  List<Card>? _passCards(Decision d) {
    if (!client.spec.sealed) return [for (final c in d.event.body['cards'] as List) Card.parse(c as String)];
    final deal = client.dealOf(d.turn.hand);
    if (deal == null) return null;
    final cards = <Card>[];
    for (final p in d.event.body['positions'] as List) {
      final c = deal.openedCardAt(p as int);
      if (c == null) return null;
      cards.add(Card.deck[c]);
    }
    return cards;
  }

  /// The next thing the view should show, and how long to wait before
  /// showing it; null when the view is waiting on a person, or the
  /// game is over.
  ({Duration delay, void Function() act})? _next(List<Decision> record) {
    // Once this device's seat is gone the shown game stops advancing
    // at all. The page draws the notice rather than the table, but a
    // screen is not a guarantee: nothing should be able to move this
    // player's cards, from a bot here or from a play recorded
    // elsewhere. The table plays their hand out without them; this
    // device simply stops following it.
    if (!client.amSeated) return null;
    // Departures recorded next take effect at once.
    if (_consumed.length < record.length && record[_consumed.length].removal) {
      final d = record[_consumed.length];
      return (
        delay: Duration.zero,
        act: () {
          _consumed.add(d);
          final seat = d.event.seat;
          if (_shownHolders[seat] is! HumanSeat) return;
          if (seat == mySeat) {
            // Never a bot on this player's own seat in the shown game.
            // The table is not drawn once the seat is gone, but the
            // shown game runs underneath whatever is drawn, and a bot
            // installed here would play this player's cards — a ghost
            // at their own hand. Their seat simply stops.
            _pendingPlay = null;
            _pendingPass = const {};
            return;
          }
          _shownHolders[seat] = BotSeat(client.spec.replacementFor(seat));
        }
      );
    }
    // The deal's own steps and the audit are the table's, not the
    // view's: taken as read the moment they are there.
    if (_consumed.length < record.length && (record[_consumed.length].turn.isDeal || record[_consumed.length].turn.isAudit)) {
      final d = record[_consumed.length];
      return (delay: Duration.zero, act: () => _consumed.add(d));
    }
    if (_shown.phase == Phase.dealing) {
      // Shown once the table has the hand: what this side can see of
      // it, the rest as card backs.
      final hand = _shown.handNumber;
      final deal = client.dealOf(hand);
      final dealt = deal != null && (client.game.handNumber > hand || client.game.phase != Phase.dealing);
      if (!dealt) return _dealNotShown(hand);
      final leader = deal.leader;
      if (leader == null) return _dealNotShown(hand);
      return (
        delay: Duration.zero,
        act: () {
          _shown.declareLeader(leader);
          _shown.deal([
            for (var s = 0; s < seatCount; s++)
              switch (deal.dealtHandOf(s)) {
                null => null,
                final cards => [for (final i in cards) Card.deck[i]],
              },
          ]);
        }
      );
    }
    if (_shown.phase == Phase.passing) {
      for (var s = 0; s < seatCount; s++) {
        if (_worksOutMove(s) && !_shown.hasPassed(s)) {
          if (!_seesHand(s)) return null; // a departed seat's hand, not open here yet
          return (delay: Duration.zero, act: () => _botActs(s, passing: true));
        }
      }
      if (_givenUp(record)) return (delay: sweepBeat, act: _giveUpShownHand);
      if (_consumed.length >= record.length) return null; // a person's pass is owed
      final d = record[_consumed.length];
      if (d.event.kind != EventKind.pass) return null; // not what the replay expects: leave it to a rebuild
      final cards = _passCards(d);
      return (
        delay: Duration.zero,
        act: () {
          _consumed.add(d);
          _declareLead();
          _shown.setPass(d.event.seat, cards);
          if (d.event.seat == mySeat) _pendingPass = const {};
        }
      );
    }
    // The game is over as shown: the beat of bare felt that ends any
    // hand, and then its sheet.
    if (_shown.phase == Phase.gameOver) {
      if (_gameOverDue) return null;
      return (delay: sweepBeat, act: () => _gameOverDue = true);
    }
    // The hand is over as shown: the same beat, then the sheet with the
    // next hand dealt under it.
    //
    // A step of the pump, rather than a timer beside it. A rebuild
    // replays the record through [_next], so anywhere _next will not
    // step past is where a rebuild leaves the shown game for good — and
    // a beat kept by a timer that the next rebuild cancels is a beat
    // that never ends: the table deals and passes the next hand while
    // this screen holds, and every decision it hears is another
    // rebuild.
    if (_shown.phase == Phase.handOver) return (delay: sweepBeat, act: _endOfHand);
    if (_shown.pendingTrick != null) return (delay: _trickHold, act: _shown.collectTrick);
    final seat = _shown.currentSeat!;
    if (_worksOutMove(seat)) {
      if (!_seesHand(seat)) return null; // a departed seat's hand, not open here yet
      return (delay: _botThink(seat), act: () => _botActs(seat, passing: false));
    }
    if (_givenUp(record)) return (delay: sweepBeat, act: _giveUpShownHand);
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

  /// What the screen is waiting on, for the debug line a driven build
  /// carries (live/live_page.dart). A table stuck from the outside is
  /// often a screen that has not caught up with it.
  String get behind => 'shown ${_shown.phase.name} h${_shown.handNumber}; consumed ${_consumed.length}/${client.record.length}; '
      'pumping $_pumping; pending ${_pendingPlay?.code ?? '-'}/${_pendingPass.length}';

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

  /// The words the table speaks in: the page sets them from the app's
  /// language (l10n/l10n.dart), and they are English until it does.
  AppLocalizations words = english;

  String _plainName(int s) => s == client.mySeat
      ? words.you
      : switch (_shownHolders[s]) {
          BotSeat(:final persona) => persona.name,
          _ => seatNames[s] ?? words.seatNumber(s + 1),
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
      client.awaitingMyPass && _shown.phase == Phase.passing && !_shown.hasPassed(mySeat) && _pendingPass.isEmpty;

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
    if (!_shown.legalPlaysFor(mySeat).contains(card)) return refusalFor(_shown, mySeat, card, words);
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
  @override
  int? clockMs(int seat) => client.clockMs(seat);

  @override
  String iconSeedOf(int seat) => switch (_shownHolders[seat]) {
        HumanSeat(:final key) => key,
        BotSeat(:final persona) => persona.name,
      };

  @override
  Avatar avatarOf(int seat) => switch (_shownHolders[seat]) {
        HumanSeat(:final key) => _asShown(key, seatAvatars[seat] ?? Avatar.none),
        BotSeat(:final persona) => Avatar.forBot(persona.name),
      };

  /// The avatar as this device will draw it: the icon and the colour
  /// they chose, and their picture only if it is allowed here.
  Avatar _asShown(String key, Avatar avatar) {
    final picture = avatar.picture;
    final pictures = this.pictures;
    if (picture == null || pictures == null) return avatar;
    return pictures.allows(key, picture) ? avatar : avatar.copyWith(clearPicture: true);
  }

  /// Whose picture the badge at [seat] is showing, for the sheet that
  /// hides it; null for a bot, for your own seat, and for a seat whose
  /// player chose no picture.
  ({String key, String name, bool hidden, bool flagged})? pictureAt(int seat) {
    final holder = _shownHolders[seat];
    final pictures = this.pictures;
    if (holder is! HumanSeat || pictures == null || seat == mySeat) return null;
    final picture = (seatAvatars[seat] ?? Avatar.none).picture;
    if (picture == null) return null;
    return (
      key: holder.key,
      name: names[seat],
      hidden: pictures.isHidden(holder.key),
      flagged: pictures.wasFlagged(holder.key, picture),
    );
  }
  void boot(int seat) {
    client.boot(seat);
    notifyListeners();
  }

  /// How long the wire is kept open after a leave is announced. The
  /// leaving is a message like any other and has to reach the relay
  /// and the peers, and the wire it goes on is this one — so it is
  /// closed a beat later rather than under its own message.
  static const leaveBeat = Duration(milliseconds: 600);
  bool _left = false;

  void leave() {
    _left = true;
    client.leave();
    notifyListeners();
  }

  /// Humans at the table and heard from lately, this device included.
  int get here => client.heardLately.length;

  /// The hand's jury: drawn and heard from.
  ({int drawn, int live}) get jury => client.jury;

  /// The table found nobody online to draw a jury from.
  bool get needsJuror => client.needsJuror;

  /// What the deal is doing, while the table deals; null otherwise.
  String? get dealNote {
    if (client.game.phase != Phase.dealing) return null;
    final d = client.deal;
    // Before there is a deal at all: a hand with bot seats waits for
    // jurors enough to hold them, because a bot seat nobody holds is
    // a hand everyone can see (docs/04-live-play.md).
    if (d == null && client.shortOfJurors) return words.waitingForJurors;
    if (d == null) return words.dealing;
    return switch (d.phase) {
      DealPhase.keys => words.dealingKeys,
      DealPhase.shuffles => words.shuffling((d.nextShuffler ?? 3) + 1),
      DealPhase.tokens => words.dealingTheCards,
      DealPhase.declare => words.openingTheCards,
      _ => words.dealing,
    };
  }

  /// The record so far, as the verifier sees it.
  Verification verification() => verifyRecord(client.spec, client.record,
      allowPartial: !client.done, juries: client.juries, crypto: _crypto, releases: client.releases);

  @override
  void dispose() {
    _disposed = true;
    _waitTimer?.cancel();
    _sheetTimer?.cancel();
    _sub?.cancel();
    _refusals?.cancel();
    pictures?.removeListener(_pictured);
    // Nothing here reacts to the table any more, whichever way this
    // goes; only the socket waits, and only for a leave that is still
    // on its way out. Waiting before the page is gone would be the
    // player standing at a table they have left.
    if (_left) {
      Timer(leaveBeat, client.close);
    } else {
      client.close();
    }
    super.dispose();
  }
}
