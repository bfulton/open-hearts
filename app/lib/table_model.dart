/// What the table's widgets need from whatever is driving the game —
/// the solo controller, or a live table's client. The views draw the
/// player at the bottom whichever seat they hold, so everything is
/// asked relative to [mySeat].
library;

import 'package:flutter/foundation.dart';

import 'package:engine/engine.dart';

abstract class TableModel implements Listenable {
  HeartsGame get game;

  /// The names around the table, seat order.
  List<String> get names;

  /// The player's own seat.
  int get mySeat;

  /// The persona at [seat], or null at a human's.
  Persona? personaAt(int seat);

  /// Every card played this hand, as the player has seen it.
  Set<Card> get playedThisHand;

  Set<Card> get selected;
  bool get awaitingPass;
  bool get canConfirmPass;
  bool get awaitingPlay;
  Set<Card> get legalNow;

  void toggleSelected(Card card);
  void confirmPass();

  /// Plays [card] for the player; null on success, else why not.
  String? playCard(Card card);

  /// Where a seat sits on screen: 0 is the player at the bottom, then
  /// clockwise — 1 left, 2 across, 3 right.
  int positionOf(int seat) => (seat - mySeat + seatCount) % seatCount;

  /// The inverse of [positionOf].
  int seatAt(int position) => (position + mySeat) % seatCount;
}

/// Why a card cannot be played right now, phrased as the rule: a Hearts
/// player learns these four sentences and then never needs them again.
String refusalFor(HeartsGame game, int seat, Card card) {
  final trick = game.trick;
  if (game.isFirstTrick && trick.isEmpty) {
    return 'The ${twoOfClubs.spoken} leads the first trick';
  }
  if (trick.isNotEmpty) {
    final led = trick.first.card.suit;
    if (card.suit != led && game.handOf(seat).any((c) => c.suit == led)) {
      return 'You have to follow ${led.name}';
    }
    if (game.isFirstTrick && cardPoints(card) > 0) {
      return 'No points on the first trick';
    }
  } else if (card.suit == Suit.hearts && !game.heartsBroken) {
    return "Hearts aren't broken yet";
  }
  return 'You cannot play that card';
}
