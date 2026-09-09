/// The Hearts game state machine.
///
/// Deterministic and synchronous: every transition is a method call that
/// either succeeds or throws [StateError]. Nothing here sleeps, animates,
/// or decides — pacing belongs to the UI and card choice to the bot, so
/// a whole game can be played out in a test in microseconds.
///
/// Two transitions deliberately do NOT happen on their own:
/// [collectTrick] and [nextHand]. A completed trick sits on the table
/// until the caller sweeps it, which is what gives the UI a beat to show
/// the fourth card without the engine knowing about time.
library;

import 'dart:math';

import 'card.dart';
import 'rules.dart';

/// Where the game is between calls.
enum Phase {
  /// Every seat owes three cards. Skipped on a hold hand.
  passing,

  /// Tricks are being played.
  playing,

  /// Thirteen tricks are in; [HeartsGame.handScores] is settled and
  /// [HeartsGame.nextHand] starts the next deal.
  handOver,

  /// Someone crossed [gameOverScore]; [HeartsGame.winners] is final.
  gameOver,
}

/// The seat the human plays. Fixed at 0 so "south" and "you" are the same
/// idea everywhere; the other three are bots.
const humanSeat = 0;

/// The number of seats. Hearts is a four-handed game and this engine does
/// not generalize — the passing rotation and the 52-card deal both assume it.
const seatCount = 4;

class HeartsGame {
  HeartsGame({int? seed}) : _random = Random(seed) {
    _startHand();
  }

  final Random _random;

  Phase get phase => _phase;
  Phase _phase = Phase.passing;

  /// Zero-based; drives the passing rotation.
  int get handNumber => _handNumber;
  int _handNumber = 0;

  PassDirection get passDirection => PassDirection.forHand(_handNumber);

  /// Running totals across hands.
  List<int> get totals => List.unmodifiable(_totals);
  final List<int> _totals = List.filled(seatCount, 0);

  /// Points each seat took in the current (or just-finished) hand, BEFORE
  /// the moon rule. [handScores] is the same numbers after it.
  List<int> get taken => List.unmodifiable(_taken);
  final List<int> _taken = List.filled(seatCount, 0);

  /// What the just-finished hand added to each total. Empty mid-hand.
  List<int> get handScores => List.unmodifiable(_handScores);
  List<int> _handScores = const [];

  /// The seat that shot the moon in the just-finished hand, or null.
  int? get moonShooter => _moonShooter;
  int? _moonShooter;

  List<Card> handOf(int seat) => List.unmodifiable(_hands[seat]);
  late List<List<Card>> _hands;

  /// Cards on the table right now, in play order.
  List<Play> get trick => List.unmodifiable(_trick);
  final List<Play> _trick = [];

  /// The finished trick still sitting on the table, waiting for
  /// [collectTrick]. Null whenever the table is live.
  ({List<Play> plays, int winner})? get pendingTrick => _pendingTrick;
  ({List<Play> plays, int winner})? _pendingTrick;

  /// Tricks completed and swept this hand, 0..13.
  int get tricksPlayed => _tricksPlayed;
  int _tricksPlayed = 0;

  bool get isFirstTrick => _tricksPlayed == 0;

  bool get heartsBroken => _heartsBroken;
  bool _heartsBroken = false;

  /// The seat on lead for the current trick.
  int get leader => _leader;
  int _leader = 0;

  /// The seat to play now, or null when the table is waiting on
  /// [collectTrick] / [nextHand] or the game is over.
  int? get currentSeat {
    if (_phase != Phase.playing || _pendingTrick != null) return null;
    return (_leader + _trick.length) % seatCount;
  }

  /// Cards a seat has committed to pass this hand; null until it chooses.
  List<Card>? passOf(int seat) => _passes[seat];
  late List<List<Card>?> _passes;

  /// Cards this seat was handed by its passing neighbour, so the UI can
  /// call them out on the first look at the new hand. Empty on a hold hand.
  List<Card> receivedBy(int seat) => List.unmodifiable(_received[seat]);
  late List<List<Card>> _received;

  /// The seat whose three cards [seat] received — the rotation run
  /// backwards. On a hold hand this is [seat] itself, which is the
  /// honest answer: nothing moved.
  int passerTo(int seat) =>
      (seat - passDirection.seatOffset + seatCount) % seatCount;

  // ---- setup ----------------------------------------------------------

  void _startHand() {
    final deck = List.of(Card.deck)..shuffle(_random);
    _hands = [
      for (var s = 0; s < seatCount; s++)
        deck.sublist(s * 13, s * 13 + 13)..sort(),
    ];
    _passes = List.filled(seatCount, null);
    _received = [for (var s = 0; s < seatCount; s++) <Card>[]];
    _trick.clear();
    _pendingTrick = null;
    _tricksPlayed = 0;
    _heartsBroken = false;
    _handScores = const [];
    _moonShooter = null;
    for (var s = 0; s < seatCount; s++) {
      _taken[s] = 0;
    }
    if (passDirection == PassDirection.hold) {
      _beginPlay();
    } else {
      _phase = Phase.passing;
    }
  }

  void _beginPlay() {
    _phase = Phase.playing;
    _leader = _hands.indexWhere((h) => h.contains(twoOfClubs));
    assert(_leader >= 0, 'someone holds the 2♣');
  }

  // ---- passing --------------------------------------------------------

  /// Commits [cards] as [seat]'s pass. Once all four seats have chosen,
  /// the swap resolves and the phase advances to [Phase.playing].
  void setPass(int seat, List<Card> cards) {
    if (_phase != Phase.passing) {
      throw StateError('not passing (phase: $_phase)');
    }
    if (cards.length != passSize) {
      throw ArgumentError('a pass is exactly $passSize cards, got ${cards.length}');
    }
    if (cards.toSet().length != passSize) {
      throw ArgumentError('a pass cannot repeat a card: $cards');
    }
    for (final c in cards) {
      if (!_hands[seat].contains(c)) {
        throw ArgumentError('seat $seat does not hold $c');
      }
    }
    _passes[seat] = List.of(cards);
    if (_passes.every((p) => p != null)) _resolvePass();
  }

  void _resolvePass() {
    final offset = passDirection.seatOffset;
    // Remove every pass before delivering any: a card must not be
    // passable and receivable in the same step.
    for (var s = 0; s < seatCount; s++) {
      _hands[s].removeWhere((c) => _passes[s]!.contains(c));
    }
    for (var s = 0; s < seatCount; s++) {
      final to = (s + offset) % seatCount;
      _received[to] = List.of(_passes[s]!);
      _hands[to].addAll(_passes[s]!);
    }
    for (final h in _hands) {
      h.sort();
    }
    _beginPlay();
  }

  // ---- playing --------------------------------------------------------

  /// The cards [seat] may legally play right now. Throws unless it is
  /// [seat]'s turn.
  List<Card> legalPlaysFor(int seat) {
    if (currentSeat != seat) {
      throw StateError('not seat $seat\'s turn (current: $currentSeat)');
    }
    return legalPlays(
      hand: _hands[seat],
      trick: _trick,
      heartsBroken: _heartsBroken,
      isFirstTrick: isFirstTrick,
    );
  }

  /// Plays [card] from [seat]. Throws [StateError] out of turn and
  /// [ArgumentError] on an illegal card — an illegal play is a bug in the
  /// caller, never a rule the engine quietly bends.
  void play(int seat, Card card) {
    if (currentSeat != seat) {
      throw StateError('not seat $seat\'s turn (current: $currentSeat)');
    }
    if (!legalPlaysFor(seat).contains(card)) {
      throw ArgumentError('$card is not a legal play for seat $seat');
    }
    _hands[seat].remove(card);
    _trick.add(Play(seat, card));
    if (card.suit == Suit.hearts) _heartsBroken = true;
    if (_trick.length == seatCount) {
      _pendingTrick = (plays: List.of(_trick), winner: trickWinner(_trick));
    }
  }

  /// Sweeps the finished trick to its winner and puts them on lead. When
  /// that was the thirteenth trick, scores the hand and moves to
  /// [Phase.handOver] (or [Phase.gameOver]).
  void collectTrick() {
    final done = _pendingTrick;
    if (done == null) throw StateError('no finished trick to collect');
    _taken[done.winner] += pointsIn(done.plays.map((p) => p.card));
    _leader = done.winner;
    _trick.clear();
    _pendingTrick = null;
    _tricksPlayed++;
    if (_tricksPlayed == 13) _finishHand();
  }

  void _finishHand() {
    _handScores = scoreHand(_taken);
    final shot = _taken.indexOf(moonPoints);
    _moonShooter = shot < 0 ? null : shot;
    for (var s = 0; s < seatCount; s++) {
      _totals[s] += _handScores[s];
    }
    _phase = _totals.any((t) => t >= gameOverScore) ? Phase.gameOver : Phase.handOver;
  }

  /// Deals the next hand. Only valid from [Phase.handOver].
  void nextHand() {
    if (_phase != Phase.handOver) {
      throw StateError('the hand is not over (phase: $_phase)');
    }
    _handNumber++;
    _startHand();
  }

  /// The winning seats, once the game is over. Ties are possible.
  List<int> get winners {
    if (_phase != Phase.gameOver) throw StateError('the game is not over');
    return lowestTotals(_totals);
  }
}
