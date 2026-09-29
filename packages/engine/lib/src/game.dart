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
///
/// A **sealed** game (docs/03-fair-deal.md) takes its cards from outside
/// rather than from the seed, and may not know every hand: a seat's
/// cards can be hidden from this side, in which case the engine tracks
/// how many it holds and checks its plays as far as the rules allow
/// without seeing them. The rest is the audit's, at the end of the hand.
library;

import 'dart:math';

import 'card.dart';
import 'rules.dart';

/// Where the game is between calls.
enum Phase {
  /// A sealed game's cards are still being dealt: nothing to see until
  /// [HeartsGame.deal]. A seeded game never rests here.
  dealing,

  /// Every seat owes three cards. Skipped on a hold hand.
  passing,

  /// Tricks are being played.
  playing,

  /// Thirteen tricks are in; [HeartsGame.handScores] is settled and
  /// [HeartsGame.nextHand] starts the next deal.
  handOver,

  /// Someone crossed [HeartsGame.target]; [HeartsGame.winners] is final.
  gameOver,
}

/// The seat the human plays. Fixed at 0 so "south" and "you" are the same
/// idea everywhere; the other three are bots.
const humanSeat = 0;

/// The number of seats. Hearts is a four-handed game and this engine does
/// not generalize — the passing rotation and the 52-card deal both assume it.
const seatCount = 4;

class HeartsGame {
  HeartsGame({int? seed, this.sealed = false, this.target = gameOverScore}) : _random = Random(seed) {
    _startHand();
  }

  final Random _random;

  /// The score this game runs to: [gameOverScore] unless the table
  /// asked for another. Every seat has to agree on it, which is why a
  /// live table carries it in the start event everyone signs
  /// (`TableSpec.target`).
  final int target;

  /// Whether the cards come from outside — the verifiable deal — rather
  /// than from the seed. Every hand of a sealed game begins in
  /// [Phase.dealing] and waits for [deal].
  final bool sealed;

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

  /// A seat's cards. Throws for a hand hidden from this side; ask
  /// [knowsHand] first at a sealed table.
  List<Card> handOf(int seat) {
    final h = _hands[seat];
    if (h == null) throw StateError('seat $seat\'s hand is hidden');
    return List.unmodifiable(h);
  }

  /// Whether this side can see [seat]'s cards. Always at a seeded
  /// table; at a sealed one, its own, the bots', and any revealed.
  bool knowsHand(int seat) => _hands[seat] != null;

  /// How many cards [seat] holds, seen or not.
  int handSizeOf(int seat) => _sizes[seat];

  late List<List<Card>?> _hands;
  late List<int> _sizes;

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

  /// Cards a seat has committed to pass this hand; null until it
  /// chooses — and null after, when the passer's hand is hidden and the
  /// cards are not this side's to see. [hasPassed] tells those apart.
  List<Card>? passOf(int seat) => _passes[seat];
  late List<List<Card>?> _passes;

  /// Whether [seat] has committed its pass, seen or not.
  bool hasPassed(int seat) => _passed[seat];
  late List<bool> _passed;

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
    _passes = List.filled(seatCount, null);
    _passed = List.filled(seatCount, false);
    _received = [for (var s = 0; s < seatCount; s++) <Card>[]];
    _trick.clear();
    _pendingTrick = null;
    _tricksPlayed = 0;
    _heartsBroken = false;
    _handScores = const [];
    _moonShooter = null;
    _declaredLeader = null;
    for (var s = 0; s < seatCount; s++) {
      _taken[s] = 0;
    }
    if (sealed) {
      _hands = List.filled(seatCount, null);
      _sizes = List.filled(seatCount, 0);
      _phase = Phase.dealing;
      return;
    }
    final deck = List.of(Card.deck)..shuffle(_random);
    _hands = [
      for (var s = 0; s < seatCount; s++)
        deck.sublist(s * 13, s * 13 + 13)..sort(),
    ];
    _sizes = List.filled(seatCount, 13);
    _dealt();
  }

  /// The cards of a sealed hand, as this side knows them: thirteen for
  /// each seat it can see, null for each it cannot. Only valid in
  /// [Phase.dealing].
  void deal(List<List<Card>?> hands) {
    if (!sealed) throw StateError('a seeded game deals itself');
    if (_phase != Phase.dealing) throw StateError('not dealing (phase: $_phase)');
    if (hands.length != seatCount) throw ArgumentError('a deal is $seatCount hands, got ${hands.length}');
    final seen = <Card>{};
    for (final h in hands) {
      if (h == null) continue;
      if (h.length != 13) throw ArgumentError('a hand is 13 cards, got ${h.length}');
      for (final c in h) {
        if (!seen.add(c)) throw ArgumentError('$c dealt twice');
      }
    }
    _hands = [for (final h in hands) h == null ? null : (List.of(h)..sort())];
    _sizes = List.filled(seatCount, 13);
    _dealt();
  }

  void _dealt() {
    if (passDirection == PassDirection.hold) {
      _beginPlay();
    } else {
      _phase = Phase.passing;
    }
  }

  /// A hidden hand, seen: what [seat] holds now, once its cards are
  /// opened to this side — a departed seat's, or everyone's at the
  /// audit. Must be as many as the seat holds.
  void revealHand(int seat, List<Card> cards) {
    if (_hands[seat] != null) throw StateError('seat $seat\'s hand is not hidden');
    if (cards.length != _sizes[seat]) {
      throw ArgumentError('seat $seat holds ${_sizes[seat]} cards, not ${cards.length}');
    }
    if (_phase == Phase.passing) {
      // A seen hand takes what is passed into it when the swap
      // resolves, so a pass into it taken as unknown has to be filled
      // in first (amendPass) — a departed seat's, opened from escrow
      // while the others' passes to it were still sealed.
      final from = (seat - passDirection.seatOffset) % seatCount;
      if (from != seat && _passed[from] && _passes[from] == null) {
        throw StateError('seat $seat\'s hand cannot be seen while seat $from\'s pass into it is unknown');
      }
    }
    for (final c in cards) {
      for (var s = 0; s < seatCount; s++) {
        if (_hands[s]?.contains(c) == true) throw ArgumentError('$c is in seat $s\'s hand');
      }
    }
    _hands[seat] = List.of(cards)..sort();
  }

  /// Who leads the first trick when no hand this side can see holds
  /// the 2♣: told from outside, where the deal knows. Before play.
  void declareLeader(int seat) {
    if (_phase != Phase.dealing && _phase != Phase.passing) {
      throw StateError('the lead is settled (phase: $_phase)');
    }
    _declaredLeader = seat;
  }

  int? _declaredLeader;

  void _beginPlay() {
    _leader = _leaderNow();
    _phase = Phase.playing;
  }

  /// The seat to lead: whoever is seen to hold the 2♣, else the
  /// declared leader. Throws when there is neither.
  int _leaderNow() {
    final seen = _hands.indexWhere((h) => h != null && h.contains(twoOfClubs));
    if (seen >= 0) return seen;
    final declared = _declaredLeader;
    if (declared == null) throw StateError('nobody seen holds the 2♣ and no leader was declared');
    return declared;
  }

  /// Whether the lead can be found once [seat] passes [cards] and the
  /// swap resolves: a seen hand ends up with the 2♣, or a leader was
  /// declared. Checked before the last pass is taken, so a refusal
  /// leaves nothing half done.
  bool _leadKnownAfter(int seat, List<Card>? cards) {
    if (_declaredLeader != null) return true;
    final offset = passDirection.seatOffset;
    for (var s = 0; s < seatCount; s++) {
      final pass = s == seat ? cards : _passes[s];
      final hand = _hands[s];
      if (hand != null && hand.contains(twoOfClubs) && !(pass?.contains(twoOfClubs) ?? false)) return true;
      if (pass != null && pass.contains(twoOfClubs) && _hands[(s + offset) % seatCount] != null) return true;
    }
    return false;
  }

  // ---- passing --------------------------------------------------------

  /// Commits [cards] as [seat]'s pass. Once all four seats have chosen,
  /// the swap resolves and the phase advances to [Phase.playing].
  ///
  /// From a hidden hand the cards may be unknown to this side — null —
  /// unless the receiver's hand is one this side sees, whose cards
  /// have to be known to be added to it.
  void setPass(int seat, List<Card>? cards) {
    if (_phase != Phase.passing) {
      throw StateError('not passing (phase: $_phase)');
    }
    if (_passed[seat]) throw StateError('seat $seat has passed');
    final hand = _hands[seat];
    if (cards == null) {
      if (hand != null) throw ArgumentError('seat $seat\'s cards are seen; its pass must be too');
      final to = (seat + passDirection.seatOffset) % seatCount;
      if (_hands[to] != null) throw ArgumentError('seat $seat\'s pass to seat $to, whose hand is seen, must be known');
    } else {
      if (cards.length != passSize) {
        throw ArgumentError('a pass is exactly $passSize cards, got ${cards.length}');
      }
      if (cards.toSet().length != passSize) {
        throw ArgumentError('a pass cannot repeat a card: $cards');
      }
      for (final c in cards) {
        if (hand != null && !hand.contains(c)) {
          throw ArgumentError('seat $seat does not hold $c');
        }
        if (hand == null) {
          for (var s = 0; s < seatCount; s++) {
            if (_hands[s]?.contains(c) == true) throw ArgumentError('$c is in seat $s\'s hand, not seat $seat\'s');
          }
        }
      }
    }
    if (_passed.where((p) => p).length == seatCount - 1 && !_leadKnownAfter(seat, cards)) {
      throw StateError('nobody seen would hold the 2♣ and no leader was declared');
    }
    _passes[seat] = cards == null ? null : List.of(cards);
    _passed[seat] = true;
    if (_passed.every((p) => p)) _resolvePass();
  }

  /// Fills in a pass taken as unknown — from a hidden hand into a
  /// hidden one — before the swap resolves: the receiver's hand is
  /// about to be seen, and a seen hand takes what came into it.
  void amendPass(int seat, List<Card> cards) {
    if (_phase != Phase.passing) throw StateError('not passing (phase: $_phase)');
    if (!_passed[seat]) throw StateError('seat $seat has not passed');
    if (_passes[seat] != null) throw StateError('seat $seat\'s pass is known');
    if (cards.length != passSize || cards.toSet().length != passSize) {
      throw ArgumentError('a pass is exactly $passSize different cards, got $cards');
    }
    for (final c in cards) {
      for (var s = 0; s < seatCount; s++) {
        if (_hands[s]?.contains(c) == true) throw ArgumentError('$c is in seat $s\'s hand, not seat $seat\'s');
      }
    }
    _passes[seat] = List.of(cards);
  }

  void _resolvePass() {
    final offset = passDirection.seatOffset;
    for (var s = 0; s < seatCount; s++) {
      final to = (s + offset) % seatCount;
      if (_hands[to] != null && _passes[s] == null) {
        // revealHand and setPass keep this from happening; a throw
        // here leaves the swap untouched rather than half done.
        throw StateError('seat $to\'s hand is seen but seat $s\'s pass into it is unknown');
      }
    }
    // Remove every pass before delivering any: a card must not be
    // passable and receivable in the same step.
    for (var s = 0; s < seatCount; s++) {
      final hand = _hands[s];
      if (hand != null) hand.removeWhere((c) => _passes[s]!.contains(c));
      _sizes[s] -= passSize;
    }
    for (var s = 0; s < seatCount; s++) {
      final to = (s + offset) % seatCount;
      final cards = _passes[s];
      _received[to] = cards == null ? const [] : List.of(cards);
      if (cards != null) _hands[to]?.addAll(cards);
      _sizes[to] += passSize;
    }
    for (final h in _hands) {
      h?.sort();
    }
    _beginPlay();
  }

  // ---- playing --------------------------------------------------------

  /// The cards [seat] may legally play right now. Throws unless it is
  /// [seat]'s turn, or when its hand is hidden from this side.
  List<Card> legalPlaysFor(int seat) {
    if (currentSeat != seat) {
      throw StateError('not seat $seat\'s turn (current: $currentSeat)');
    }
    return legalPlays(
      hand: handOf(seat),
      trick: _trick,
      heartsBroken: _heartsBroken,
      isFirstTrick: isFirstTrick,
    );
  }

  /// Whether [card] can be [play]ed by [seat] now, as far as this side
  /// can tell: the full rules over a hand it sees, [legalFromHidden]
  /// over one it does not.
  bool allows(int seat, Card card) {
    if (currentSeat != seat) return false;
    final hand = _hands[seat];
    if (hand == null) return legalFromHidden(card: card, trick: _trick, isFirstTrick: isFirstTrick);
    return legalPlays(hand: hand, trick: _trick, heartsBroken: _heartsBroken, isFirstTrick: isFirstTrick).contains(card);
  }

  /// Plays [card] from [seat]. Throws [StateError] out of turn and
  /// [ArgumentError] on an illegal card — an illegal play is a bug in the
  /// caller, never a rule the engine quietly bends. From a hidden hand
  /// the card is checked as far as the rules allow without the hand.
  void play(int seat, Card card) {
    if (currentSeat != seat) {
      throw StateError('not seat $seat\'s turn (current: $currentSeat)');
    }
    if (!allows(seat, card)) {
      throw ArgumentError('$card is not a legal play for seat $seat');
    }
    final hand = _hands[seat];
    if (hand == null) {
      if (_sizes[seat] == 0) throw StateError('seat $seat has no cards');
      for (var s = 0; s < seatCount; s++) {
        if (_hands[s]?.contains(card) == true) throw ArgumentError('$card is in seat $s\'s hand, not seat $seat\'s');
      }
    } else {
      hand.remove(card);
    }
    _sizes[seat]--;
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
    _phase = _totals.any((t) => t >= target) ? Phase.gameOver : Phase.handOver;
  }

  /// A hand given up, and the next one dealt in its place. Nothing is
  /// scored: no hand happened.
  ///
  /// There is one reason for it and it is not a rule of Hearts. At a
  /// sealed table (docs/03-fair-deal.md) a seat that holds the two of
  /// clubs can say it holds it nowhere: nothing can be made to prove
  /// otherwise, and nobody can lead. No hand can be got out of that, so
  /// it is given up; what the table does about the seat is the table's
  /// business (packages/table), and what the game does is deal again.
  ///
  /// Not valid once a hand is over: a hand that reached its score is
  /// scored ([nextHand]).
  void abandonHand() {
    if (_phase == Phase.handOver || _phase == Phase.gameOver) {
      throw StateError('a hand that is over is scored, not given up (phase: $_phase)');
    }
    _handNumber++;
    _startHand();
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
