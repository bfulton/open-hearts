/// What the table's widgets need from whatever is driving the game —
/// the solo controller, or a live table's client. The views draw the
/// player at the bottom whichever seat they hold, so everything is
/// asked relative to [mySeat].
library;

import 'package:flutter/foundation.dart';

import 'package:engine/engine.dart';

import 'avatar.dart';
import 'l10n/l10n.dart';

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

  /// The player's card on the table ahead of the table's word on it —
  /// a live table shows it the instant it is tapped. Null elsewhere.
  Card? get pendingPlay => null;

  /// Cards the player has committed that the game as shown has not yet
  /// taken from the hand: a pending play, a pending pass.
  Set<Card> get inFlight => const {};

  /// What [seat]'s icon is coloured from (ui/player_icon.dart): a
  /// person's key, a bot's name — the same on every screen.
  String iconSeedOf(int seat);

  /// How [seat] chose to look (avatar.dart); a bot's is its own.
  Avatar avatarOf(int seat);

  /// Milliseconds [seat] has left on its clock, once the grace on its
  /// open decision is spent (docs/04, "Boot"); null while there is no
  /// clock to show — within the grace, off turn, a bot, or a solo
  /// table, which has none.
  int? clockMs(int seat);

  /// The three the player passed, while the others are still choosing:
  /// off the hand and up on the line, so what went is in view until the
  /// pass resolves. Empty at every other moment.
  Set<Card> get passed => const {};

  /// Where a seat sits on screen: 0 is the player at the bottom, then
  /// clockwise — 1 left, 2 across, 3 right.
  int positionOf(int seat) => (seat - mySeat + seatCount) % seatCount;

  /// The inverse of [positionOf].
  int seatAt(int position) => (position + mySeat) % seatCount;
}

extension TableModelHand on TableModel {
  /// The hand as the player holds it: what the game deals them, less
  /// what they have committed.
  List<Card> get handShown => [
        for (final c in game.handOf(mySeat))
          if (!inFlight.contains(c) && !passed.contains(c)) c,
      ];
}

/// Why a card cannot be played right now, phrased as the rule: a Hearts
/// player learns these four sentences and then never needs them again.
String refusalFor(HeartsGame game, int seat, Card card, [AppLocalizations? words]) {
  final say = words ?? english;
  final trick = game.trick;
  if (game.isFirstTrick && trick.isEmpty) {
    return say.refuseFirstLead;
  }
  if (trick.isNotEmpty) {
    final led = trick.first.card.suit;
    if (card.suit != led && game.handOf(seat).any((c) => c.suit == led)) {
      return say.refuseFollowSuit(led.name);
    }
    if (game.isFirstTrick && cardPoints(card) > 0) {
      return say.refuseFirstTrickPoints;
    }
  } else if (card.suit == Suit.hearts && !game.heartsBroken) {
    return say.refuseHeartsUnbroken;
  }
  return say.refuseOther;
}
