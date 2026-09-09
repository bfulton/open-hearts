/// The rules of Hearts, as pure functions over hands and tricks.
///
/// Nothing here holds state or knows about players-as-people: every
/// function takes what it needs and returns a value. [HeartsGame] in
/// game.dart is the only thing that sequences them, and the bot in
/// bot.dart reads them to decide. Keeping the rules callable in
/// isolation is what makes them testable without dealing a game.
library;

import 'card.dart';

/// Points a single card contributes to the taker's score.
int cardPoints(Card card) {
  if (card == queenOfSpades) return 13;
  return card.suit == Suit.hearts ? 1 : 0;
}

/// Points in a set of cards. A full hand's tricks always total [moonPoints].
int pointsIn(Iterable<Card> cards) =>
    cards.fold(0, (sum, c) => sum + cardPoints(c));

/// All the points in one deal: 13 hearts + the queen.
const moonPoints = 26;

/// Where the three passed cards go, by hand number.
///
/// The cycle is fixed at four and the fourth hand is a hold — that
/// rotation is what keeps a passing strategy from going stale.
enum PassDirection {
  left(1, 'Pass left'),
  right(3, 'Pass right'),
  across(2, 'Pass across'),
  hold(0, 'No pass');

  const PassDirection(this.seatOffset, this.label);

  /// Added to the passer's seat (mod 4) to find the receiver. Seats are
  /// numbered in play order, so +1 is the player who plays next — the
  /// one drawn to the left of the table.
  final int seatOffset;

  final String label;

  /// The direction for a zero-based hand number.
  static PassDirection forHand(int handNumber) =>
      const [left, right, across, hold][handNumber % 4];
}

/// How many cards each player passes when the direction is not [PassDirection.hold].
const passSize = 3;

/// One card played by one seat.
class Play {
  const Play(this.seat, this.card);

  final int seat;
  final Card card;

  @override
  String toString() => '$seat:$card';
}

/// The seat that wins a completed (or partial) trick: the highest card of
/// the suit that was led. Off-suit cards cannot win, however high.
int trickWinner(List<Play> trick) {
  assert(trick.isNotEmpty);
  final led = trick.first.card.suit;
  var best = trick.first;
  for (final play in trick.skip(1)) {
    if (play.card.suit == led && play.card.rank.value > best.card.rank.value) {
      best = play;
    }
  }
  return best.seat;
}

/// The cards [hand] may legally play into [trick].
///
/// Encodes four rules, in the order they bind:
///
///  1. The first trick of a hand is led with the 2♣, always.
///  2. Follow the led suit if you hold it.
///  3. Hearts may not be *led* until they are broken — unless hearts are
///     all you have left.
///  4. No point card (heart or Q♠) may be played to the first trick,
///     unless the restriction would leave you nothing to play.
///
/// Rule 4 is written as a filter that yields rather than a filter that
/// can empty the set: a player holding nothing but points on trick one
/// still has to play something.
///
/// [heartsBroken] means a heart has been played to some earlier trick.
/// The Q♠ does not break hearts (that is a house variant, not the
/// standard rule).
List<Card> legalPlays({
  required List<Card> hand,
  required List<Play> trick,
  required bool heartsBroken,
  required bool isFirstTrick,
}) {
  assert(hand.isNotEmpty);

  if (trick.isEmpty) {
    // Leading.
    if (isFirstTrick) {
      // Only the 2♣ holder can be on lead here, and only that card.
      assert(hand.contains(twoOfClubs));
      return [twoOfClubs];
    }
    if (!heartsBroken) {
      final nonHearts = hand.where((c) => c.suit != Suit.hearts).toList();
      // A hand of nothing but hearts leads a heart, broken or not.
      if (nonHearts.isNotEmpty) return nonHearts;
    }
    return List.of(hand);
  }

  // Following.
  final led = trick.first.card.suit;
  final following = hand.where((c) => c.suit == led).toList();
  final candidates = following.isNotEmpty ? following : List.of(hand);

  if (isFirstTrick) {
    final pointless = candidates.where((c) => cardPoints(c) == 0).toList();
    // Yields when points are all that is left — the "unless you have no
    // other choice" half of the rule.
    if (pointless.isNotEmpty) return pointless;
  }
  return candidates;
}

/// Turns one deal's per-seat trick take into per-seat scores, applying
/// the shot-moon rule.
///
/// Standard scoring: a player who takes all 26 scores nothing and every
/// other seat takes 26. (The variant where the shooter subtracts 26
/// instead is a house rule; this engine does not offer it.)
List<int> scoreHand(List<int> takenPoints) {
  assert(takenPoints.length == 4);
  assert(takenPoints.fold(0, (a, b) => a + b) == moonPoints,
      'a deal always yields exactly $moonPoints points');
  final shooter = takenPoints.indexOf(moonPoints);
  if (shooter < 0) return List.of(takenPoints);
  return [for (var s = 0; s < 4; s++) s == shooter ? 0 : moonPoints];
}

/// The score at which the game ends. Play stops at the end of the hand in
/// which any player reaches it; lowest total wins.
const gameOverScore = 100;

/// The seats holding the lowest total. Once [gameOverScore] has been
/// reached these are the winners; more than one seat can be returned,
/// because a tie is a real outcome and not an error to break.
List<int> lowestTotals(List<int> totals) {
  final low = totals.reduce((a, b) => a < b ? a : b);
  return [for (var s = 0; s < totals.length; s++) if (totals[s] == low) s];
}
