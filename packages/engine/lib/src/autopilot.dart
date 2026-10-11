/// When the rest of a hand can be left to play itself.
///
/// Late in a hand the cards often stop mattering: whatever the player
/// does with what they hold, the hand comes out the same. Tapping out
/// those cards one by one is a chore, so the table offers to do it
/// (the "Auto" switch by the hand). This is the judgement of when that
/// is so, as a pure function over what the screen shows now — the
/// hand, the trick on the felt, the trick just taken, the points the
/// badges say have been taken. Never over a memory of earlier tricks:
/// a player can check every reason given here by looking at the table.
///
/// Each reason, once it holds, holds for the rest of the hand (the
/// table keeps the switch up once it has offered it). And each is
/// about the player's own choices only: what the others do is theirs.
library;

import 'dart:math' show max;

import 'card.dart';
import 'rules.dart';

/// Why a hand can play itself out.
enum PlaysItself {
  /// Every heart and the Q♠ have been taken: nothing left to score, so
  /// nothing left to win or lose.
  noPointsLeft,

  /// The hand is one suit, ranks side by side (6-7-8♣). No card anyone
  /// else holds falls between two of them, so each compares the same
  /// against everything the others play, and which goes when makes no
  /// difference. Not with the Q♠ among others: she is worth 13 and her
  /// neighbours are not.
  oneSuitRun,

  /// Every card held tops its suit with the ones above it (A, A-K,
  /// A-K-Q…), and the player is leading or can follow: they take every
  /// remaining trick, and every point in them, in any order. Void in
  /// the suit led it does not hold — the discard goes to someone else.
  unbeatable,

  /// The player led the trick just taken, the other three all showed
  /// out of the suit, and that suit is all the player has left: they
  /// lead every trick to come and nobody can follow.
  shownOut,

  /// The player can take no trick from here on, and holds no points.
  /// They cannot take the trick on the felt; every card they hold is
  /// the lowest of its suit that is still to be played, so any card
  /// anyone else leads in it is higher; and taking nothing, they lead
  /// nothing. Their cards fall where they may, worth nothing to anyone.
  cannotWin,
}

/// Why nothing [seat] still holds in [hand] can change how the hand
/// comes out, or null when something can. Null with fewer than two
/// cards: one card is no choice at all, and nothing to save.
///
/// [trick] is the trick on the felt. [toPlay] says it is [seat]'s turn
/// to play to it — whether they are leading or following is only known
/// then, so [PlaysItself.unbeatable] and [PlaysItself.cannotWin] are
/// only judged then. [lastTrick] is
/// the trick most recently taken this hand, all four cards (empty
/// before the first is taken). [pointsTaken] is the points every seat
/// has taken this hand, the trick being taken included.
PlaysItself? whyHandPlaysItself({
  required List<Card> hand,
  required List<Play> trick,
  required bool toPlay,
  required int seat,
  List<Play> lastTrick = const [],
  required int pointsTaken,
}) {
  if (hand.length < 2) return null;

  // 1. All 26 are gone to tricks already taken; what is left scores
  // nothing for anybody. Cards still on the felt are not counted: a
  // trick being played can still go either way.
  if (pointsTaken >= moonPoints) return PlaysItself.noPointsLeft;

  // 2. One suit, unbroken. Absolute adjacency: 6-7-8 is a run whoever
  // holds the 5 and the 9, because nobody can hold a card between them.
  final suit = hand.first.suit;
  if (hand.every((c) => c.suit == suit) && !hand.contains(queenOfSpades)) {
    final ranks = [for (final c in hand) c.rank.value]..sort();
    var unbroken = true;
    for (var i = 1; i < ranks.length; i++) {
      if (ranks[i] != ranks[i - 1] + 1) unbroken = false;
    }
    if (unbroken) return PlaysItself.oneSuitRun;
  }

  // 3. Everything held is the top of its suit. Any card of a suit is
  // then higher than anything the others hold in it, so whoever leads
  // it, it wins — and the player leads the next.
  if (toPlay && hand.every((c) => _topsItsSuit(c, hand))) {
    final leading = trick.isEmpty;
    if (leading || hand.any((c) => c.suit == trick.first.card.suit)) return PlaysItself.unbeatable;
  }

  // 4. The player led the last trick and nobody followed: the others
  // hold none of that suit, it is all the player has, and they lead
  // again. Every trick to come is the same trick.
  if (lastTrick.length == 4 && lastTrick.first.seat == seat) {
    final led = lastTrick.first.card.suit;
    final shown = lastTrick.skip(1).every((p) => p.card.suit != led);
    if (shown && hand.every((c) => c.suit == led)) return PlaysItself.shownOut;
  }

  // 5. Following, with nothing that can take a trick now or later, and
  // nothing worth a point to put anywhere.
  if (toPlay && trick.isNotEmpty && pointsIn(hand) == 0) {
    final led = trick.first.card.suit;
    final top = trick.where((p) => p.card.suit == led).map((p) => p.card.rank.value).reduce(max);
    final takesThis = hand.any((c) => c.suit == led && c.rank.value > top);
    // Gone, as the table shows it: on the felt, in the trick just
    // taken, or the 2♣, which opens every hand.
    final gone = {for (final p in trick) p.card, for (final p in lastTrick) p.card, twoOfClubs};
    if (!takesThis && hand.every((c) => _bottomOfItsSuit(c, hand, gone))) return PlaysItself.cannotWin;
  }

  return null;
}

/// Whether every card of [card]'s suit below it is in [hand] or [gone]:
/// then any card of the suit anyone else can still play is higher.
bool _bottomOfItsSuit(Card card, List<Card> hand, Set<Card> gone) {
  for (var v = Rank.two.value; v < card.rank.value; v++) {
    final below = Card.of(card.suit, Rank.values[v - 2]);
    if (!hand.contains(below) && !gone.contains(below)) return false;
  }
  return true;
}

/// Whether [card] is the ace of its suit or sits under an unbroken run
/// of [hand]'s own cards down from it.
bool _topsItsSuit(Card card, List<Card> hand) {
  for (var v = card.rank.value + 1; v <= Rank.ace.value; v++) {
    if (!hand.contains(Card.of(card.suit, Rank.values[v - 2]))) return false;
  }
  return true;
}

/// The card the table plays for a player on auto: the rightmost of
/// [legal] in [hand] as it is drawn. One fixed rule, so the player
/// can see which card is coming.
Card autoPlayCard(List<Card> hand, Iterable<Card> legal) =>
    hand.lastWhere((c) => legal.contains(c));
