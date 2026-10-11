/// Drives [HeartsGame] for a human at seat 0.
///
/// The engine is synchronous and has no idea what a second is; this is
/// where waiting lives. One pump loop advances the game until it reaches
/// something only the player can do — choose a pass, or play a card —
/// and stops there.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:engine/engine.dart';

import 'avatar.dart';
import 'l10n/l10n.dart';
import 'record_store.dart';
import 'table_model.dart';

class GameController extends ChangeNotifier implements TableModel {
  GameController({this.seed, this.paced = true, this.target = gameOverScore, RecordStore? store})
      : _store = store ?? PrefsRecordStore() {
    _start();
  }

  /// Fixes the shuffle, so [newGame] reshuffles the same way a test
  /// expects: dealt by [Random] from it. Null in the app, where every
  /// game is a fresh draw of a [DealSeed].
  final int? seed;

  /// The score this game runs to, and every game after it on this
  /// screen: the player's own choice (game_options.dart).
  final int target;

  final RecordStore _store;

  /// This game as a line of text: the deal, the bots, and the player's
  /// own passes and plays. Everything the bots did follows from those.
  late SoloRecord _record;
  bool _saved = false;

  String get recordText => _record.encode();

  void _start() {
    // A player's game is dealt from 256 bits of the platform's secure
    // generator, drawn once when it starts, and its record names them
    // (engine, deal_seed.dart); a test's from its seed, by Random.
    final dealSeed = seed == null ? DealSeed.draw() : null;
    _game = HeartsGame(seed: seed, dealSeed: dealSeed, target: target);
    _bots = _seatBots(seed == null ? Random.secure() : Random(seed));
    _record = SoloRecord(
      seed: seed,
      dealSeed: dealSeed,
      personas: [for (var s = 0; s < seatCount; s++) s == humanSeat ? '' : _bots[s]!.persona.name],
      target: target,
    );
    _saved = false;
    _sheetDue = false;
    _auto.reset();
    _played.clear();
    _selected.clear();
    _pump();
  }

  /// False in tests: every wait collapses to zero so a game runs at
  /// engine speed.
  final bool paced;

  late HeartsGame _game;

  /// Who holds each seat; null at the player's. Three from the roster:
  /// drawn by a test's seed, so a seeded table is the same table, and
  /// otherwise by the secure generator. The record names them, so
  /// nothing has to draw them again.
  late List<Bot?> _bots;

  final Random _rhythm = Random();

  @override
  HeartsGame get game => _game;

  @override
  int get mySeat => humanSeat;

  @override
  int positionOf(int seat) => (seat - mySeat + seatCount) % seatCount;

  @override
  int seatAt(int position) => (position + mySeat) % seatCount;

  /// The words the table speaks in: the page sets them from the app's
  /// language (l10n/l10n.dart), and they are English until it does.
  AppLocalizations words = english;

  /// The names around the table, seat order (0 is the player).
  @override
  List<String> get names =>
      [for (var s = 0; s < seatCount; s++) s == humanSeat ? words.you : _bots[s]!.persona.name];

  /// The persona at [seat], or null at the player's.
  @override
  Persona? personaAt(int seat) => _bots[seat]?.persona;

  static List<Bot?> _seatBots(Random random) {
    final draw = List.of(Persona.roster)..shuffle(random);
    return [
      for (var s = 0; s < seatCount; s++)
        s == humanSeat ? null : Bot(persona: draw[s]),
    ];
  }

  /// Every card played this hand, which is what a seated player would
  /// have seen. Feeds [BotView.played] — the bots read the table, not
  /// each other's hands.
  final Set<Card> _played = {};
  @override
  Set<Card> get playedThisHand => Set.unmodifiable(_played);

  /// The player's in-progress pass selection.
  final Set<Card> _selected = {};
  @override
  Set<Card> get selected => Set.unmodifiable(_selected);

  bool _disposed = false;
  bool _pumping = false;

  /// How long [seat]'s bot appears to think: its persona's rhythm.
  Duration _botThink(int seat) {
    if (!paced) return Duration.zero;
    final pace = _bots[seat]!.persona.pace;
    return Duration(milliseconds: pace.minMs + _rhythm.nextInt(pace.maxMs - pace.minMs + 1));
  }
  Duration get _trickHold => paced ? const Duration(milliseconds: 950) : Duration.zero;
  /// How long the player's three sit on the line, gone from the hand,
  /// before the others' come back: the swap is seen as a swap.
  Duration get _passBeat => paced ? const Duration(milliseconds: 900) : Duration.zero;

  /// After the last trick of a hand is swept, a beat of bare felt
  /// before the sheet. Long enough to watch the last trick go to
  /// whoever took it and to take the felt in after: a sheet that comes
  /// down on the tail of the cards leaves the hand's last thing
  /// unseen, and the score it is about unexplained.
  static const sweepBeat = Duration(milliseconds: 1200);
  Duration get _sweepBeat => paced ? sweepBeat : Duration.zero;

  /// Whether the score sheet may show: the hand (or the game) is over
  /// and its last trick has been seen off the table.
  bool get sheetDue => _sheetDue;
  bool _sheetDue = false;

  // ---- what the view asks ---------------------------------------------

  @override
  bool get awaitingPass =>
      _game.phase == Phase.passing && _game.passOf(humanSeat) == null;

  @override
  bool get canConfirmPass => awaitingPass && _selected.length == passSize;

  @override
  bool get awaitingPlay =>
      _game.phase == Phase.playing && _game.currentSeat == humanSeat;

  /// The player's legal cards, or empty when it is not their turn.
  @override
  Set<Card> get legalNow =>
      awaitingPlay ? _game.legalPlaysFor(humanSeat).toSet() : const {};

  // ---- what the player does -------------------------------------------

  @override
  void toggleSelected(Card card) {
    if (!awaitingPass) return;
    if (_selected.contains(card)) {
      _selected.remove(card);
    } else {
      if (_selected.length == passSize) return;
      _selected.add(card);
    }
    notifyListeners();
  }

  @override
  void confirmPass() {
    if (!canConfirmPass) return;
    _record.passes.add(_selected.toList());
    _game.setPass(humanSeat, _selected.toList());
    _selected.clear();
    notifyListeners();
    _pump();
  }

  @override
  Card? get pendingPlay => null;

  @override
  Set<Card> get inFlight => const {};

  @override
  String iconSeedOf(int seat) => seat == humanSeat ? (mySeed.isEmpty ? 'you' : mySeed) : _bots[seat]!.persona.name;

  @override
  String iconNameOf(int seat) => seat == humanSeat && myName.isNotEmpty ? myName : names[seat];

  /// The player's name and colour as their profile has them (home_page.dart):
  /// their icon here is the one they chose, or else their initials on
  /// their account's colour, as on every other screen.
  String myName = '';
  String mySeed = '';

  /// The player's own avatar, once the page has read it off the
  /// device; the bots' are their own.
  Avatar myAvatar = Avatar.none;

  @override
  Avatar avatarOf(int seat) => seat == humanSeat ? myAvatar : Avatar.forBot(_bots[seat]!.persona.name);

  /// No clock at a solo table: the bots wait for you.
  @override
  int? clockMs(int seat) => null;

  /// No reactions at a solo table: bots do not react, and there is
  /// nobody else to react to.
  @override
  SeatReaction? reactionAt(int seat) => null;

  @override
  String nameAlone(int seat) => names[seat];

  @override
  Set<Card> get passed =>
      _game.phase == Phase.passing ? (_game.passOf(humanSeat) ?? const []).toSet() : const {};

  /// Plays [card] for the player. Returns null on success, or a short
  /// reason the card is not playable — the message the table shows when
  /// a dimmed card is tapped.
  @override
  String? playCard(Card card) {
    if (!awaitingPlay) return null;
    final legal = _game.legalPlaysFor(humanSeat);
    if (!legal.contains(card)) return refusalFor(_game, humanSeat, card, words);
    _playMine(card);
    _pump();
    return null;
  }

  /// The player's card, played: by their hand, or by the Auto switch.
  void _playMine(Card card) {
    _record.plays.add(card);
    _game.play(humanSeat, card);
    _played.add(card);
    notifyListeners();
  }

  // ---- the Auto switch -------------------------------------------------

  final AutoPilot _auto = AutoPilot();

  @override
  bool get autoOffered => _auto.offered(this);

  @override
  bool get autoPlay => _auto.on;

  /// On, and the player's turn — if it is theirs now — is played at
  /// once; the pump plays every one after it as it comes round.
  @override
  void setAutoPlay(bool on) {
    _auto.set(this, on);
    notifyListeners();
    if (on) _pump();
  }

  /// Every change the table shows is one the switch may be offered on.
  @override
  void notifyListeners() {
    _auto.watch(this);
    super.notifyListeners();
  }

  void nextHand() {
    if (_game.phase != Phase.handOver) return;
    _sheetDue = false;
    _game.nextHand();
    if (_game.passDirection == PassDirection.hold) _record.passes.add(null);
    _played.clear();
    _selected.clear();
    notifyListeners();
    _pump();
  }

  void newGame() {
    _start();
    notifyListeners();
  }

  // ---- the pump --------------------------------------------------------

  /// Advances the game as far as it can go without the player, waiting
  /// between steps so the table is readable. Re-entrant calls are
  /// dropped: one loop runs at a time and it always ends on the player.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed) {
        if (_game.phase == Phase.passing) {
          if (_game.passOf(humanSeat) == null) break; // the player owes cards
          // The bots take a moment over theirs, with the player's three
          // already off the hand and on the line; then the pass resolves
          // and three come back.
          if (!await _wait(_passBeat)) return;
          for (var s = 0; s < seatCount; s++) {
            if (s != humanSeat && _game.passOf(s) == null) {
              _game.setPass(s, _bots[s]!.choosePass(_game.handOf(s)));
            }
          }
          notifyListeners();
          continue;
        }

        if (_game.phase == Phase.gameOver) {
          if (!_saved) {
            _saved = true;
            unawaited(_store.save(_record.encode()));
          }
          break;
        }
        if (_game.phase != Phase.playing) break; // handOver

        if (_game.pendingTrick != null) {
          if (!await _wait(_trickHold)) return;
          _game.collectTrick();
          notifyListeners();
          if (_game.phase != Phase.playing) {
            // The hand's last trick: let it be seen leaving the table
            // before the sheet comes down over it.
            if (!await _wait(_sweepBeat)) return;
            _sheetDue = true;
            notifyListeners();
          }
          continue;
        }

        final seat = _game.currentSeat!;
        if (seat == humanSeat) {
          // The player's turn: theirs to take, unless the Auto switch is
          // on, in which case it is played at once — no thinking beat,
          // since nobody is thinking.
          _auto.watch(this);
          final card = _auto.cardFor(this);
          if (card == null) break;
          _playMine(card);
          continue;
        }

        if (!await _wait(_botThink(seat))) return;
        final legal = _game.legalPlaysFor(seat);
        final card = _bots[seat]!.chooseCard(_viewFor(seat), legal);
        _game.play(seat, card);
        _played.add(card);
        notifyListeners();
      }
    } finally {
      _pumping = false;
    }
  }

  Timer? _waitTimer;

  /// Sleeps, and reports whether the controller is still alive after —
  /// every await point is a place the widget can be torn down.
  ///
  /// A timer the controller can cancel, rather than a delayed future,
  /// which nothing can: a beat should not outlive the page it is
  /// pacing. The live table cancels its own the same way.
  Future<bool> _wait(Duration d) async {
    if (d > Duration.zero) {
      final done = Completer<void>();
      _waitTimer?.cancel();
      _waitTimer = Timer(d * tableBeats, done.complete);
      await done.future;
    }
    return !_disposed;
  }

  BotView _viewFor(int seat) => BotView(
        seat: seat,
        hand: _game.handOf(seat),
        trick: _game.trick,
        played: _played,
        heartsBroken: _game.heartsBroken,
        isFirstTrick: _game.isFirstTrick,
        taken: _game.taken,
      );

  @override
  void dispose() {
    _disposed = true;
    _waitTimer?.cancel();
    super.dispose();
  }
}
