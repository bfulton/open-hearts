/// Drives [HeartsGame] for a human at seat 0.
///
/// The engine is synchronous and has no idea what a second is; this is
/// where waiting lives. One pump loop advances the game until it reaches
/// something only the player can do — choose a pass, or play a card —
/// and stops there.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine/bot.dart';
import 'engine/card.dart';
import 'engine/game.dart';
import 'engine/rules.dart';

/// The names around the table, seat order (0 is the player).
const seatNames = ['You', 'West', 'North', 'East'];

class GameController extends ChangeNotifier {
  GameController({int? seed, this.paced = true})
      : _seed = seed,
        _game = HeartsGame(seed: seed),
        _bot = Bot() {
    _pump();
  }

  /// Kept so [newGame] reshuffles the same way a test expects. Null in
  /// the app, where every game should be a fresh shuffle.
  final int? _seed;

  /// False in tests: every wait collapses to zero so a game runs at
  /// engine speed.
  final bool paced;

  HeartsGame _game;
  final Bot _bot;

  HeartsGame get game => _game;

  /// Every card played this hand, which is what a seated player would
  /// have seen. Feeds [BotView.played] — the bots read the table, not
  /// each other's hands.
  final Set<Card> _played = {};
  Set<Card> get playedThisHand => Set.unmodifiable(_played);

  /// The player's in-progress pass selection.
  final Set<Card> _selected = {};
  Set<Card> get selected => Set.unmodifiable(_selected);

  bool _disposed = false;
  bool _pumping = false;

  Duration get _botThink => paced ? const Duration(milliseconds: 600) : Duration.zero;
  Duration get _trickHold => paced ? const Duration(milliseconds: 950) : Duration.zero;
  Duration get _passBeat => paced ? const Duration(milliseconds: 350) : Duration.zero;

  // ---- what the view asks ---------------------------------------------

  bool get awaitingPass =>
      _game.phase == Phase.passing && _game.passOf(humanSeat) == null;

  bool get canConfirmPass => awaitingPass && _selected.length == passSize;

  bool get awaitingPlay =>
      _game.phase == Phase.playing && _game.currentSeat == humanSeat;

  /// The player's legal cards, or empty when it is not their turn.
  Set<Card> get legalNow =>
      awaitingPlay ? _game.legalPlaysFor(humanSeat).toSet() : const {};

  // ---- what the player does -------------------------------------------

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

  void confirmPass() {
    if (!canConfirmPass) return;
    _game.setPass(humanSeat, _selected.toList());
    _selected.clear();
    notifyListeners();
    _pump();
  }

  /// Plays [card] for the player. Returns null on success, or a short
  /// reason the card is not playable — the message the table shows when
  /// a dimmed card is tapped.
  String? playCard(Card card) {
    if (!awaitingPlay) return null;
    final legal = _game.legalPlaysFor(humanSeat);
    if (!legal.contains(card)) return _refusal(card);
    _game.play(humanSeat, card);
    _played.add(card);
    notifyListeners();
    _pump();
    return null;
  }

  /// Why [card] cannot be played right now. Phrased as the rule, not as
  /// an error: a Hearts player learns these four sentences and then never
  /// needs them again.
  String _refusal(Card card) {
    final trick = _game.trick;
    if (_game.isFirstTrick && trick.isEmpty) {
      return 'The ${twoOfClubs.spoken} leads the first trick';
    }
    if (trick.isNotEmpty) {
      final led = trick.first.card.suit;
      if (card.suit != led && _game.handOf(humanSeat).any((c) => c.suit == led)) {
        return 'You have to follow ${led.name}';
      }
      if (_game.isFirstTrick && cardPoints(card) > 0) {
        return 'No points on the first trick';
      }
    } else if (card.suit == Suit.hearts && !_game.heartsBroken) {
      return "Hearts aren't broken yet";
    }
    return 'You cannot play that card';
  }

  void nextHand() {
    if (_game.phase != Phase.handOver) return;
    _game.nextHand();
    _played.clear();
    _selected.clear();
    notifyListeners();
    _pump();
  }

  void newGame() {
    _game = HeartsGame(seed: _seed);
    _played.clear();
    _selected.clear();
    notifyListeners();
    _pump();
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
          for (var s = 0; s < seatCount; s++) {
            if (s != humanSeat && _game.passOf(s) == null) {
              _game.setPass(s, _bot.choosePass(_game.handOf(s)));
            }
          }
          if (!await _wait(_passBeat)) return;
          notifyListeners();
          continue;
        }

        if (_game.phase != Phase.playing) break; // handOver / gameOver

        if (_game.pendingTrick != null) {
          if (!await _wait(_trickHold)) return;
          _game.collectTrick();
          notifyListeners();
          continue;
        }

        final seat = _game.currentSeat!;
        if (seat == humanSeat) break; // the player's turn

        if (!await _wait(_botThink)) return;
        final legal = _game.legalPlaysFor(seat);
        final card = _bot.chooseCard(_viewFor(seat), legal);
        _game.play(seat, card);
        _played.add(card);
        notifyListeners();
      }
    } finally {
      _pumping = false;
    }
  }

  /// Sleeps, and reports whether the controller is still alive after —
  /// every await point is a place the widget can be torn down.
  Future<bool> _wait(Duration d) async {
    if (d > Duration.zero) await Future<void>.delayed(d);
    return !_disposed;
  }

  BotView _viewFor(int seat) => BotView(
        seat: seat,
        hand: _game.handOf(seat),
        trick: _game.trick,
        played: _played,
        heartsBroken: _game.heartsBroken,
        isFirstTrick: _game.isFirstTrick,
      );

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
