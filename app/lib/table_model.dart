/// What the table's widgets need from whatever is driving the game —
/// the solo controller, or a live table's client. The views draw the
/// player at the bottom whichever seat they hold, so everything is
/// asked relative to [mySeat].
library;

import 'package:flutter/foundation.dart';

import 'package:engine/engine.dart';
import 'package:table/table.dart' show Reaction;

import 'avatar.dart';
import 'l10n/l10n.dart';

/// A reaction showing at a seat, and which of this screen's it is: a
/// second 👍 from the same seat is a new bubble, said aloud again.
typedef SeatReaction = ({Reaction reaction, int n});

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

  /// What [seat]'s icon takes its initials from, where nothing was
  /// chosen: its name, except the player's own seat, which is labelled
  /// "You" but wears the initials of the name on their profile.
  String iconNameOf(int seat) => names[seat];

  /// How [seat] chose to look (avatar.dart); a bot's is its own.
  Avatar avatarOf(int seat);

  /// Milliseconds [seat] has left on its clock, once the grace on its
  /// open decision is spent (docs/04-live-play.md); null while there is no
  /// clock to show — within the grace, off turn, a bot, or a solo
  /// table, which has none.
  int? clockMs(int seat);

  /// The three the player passed, while the others are still choosing:
  /// off the hand and up on the line, so what went is in view until the
  /// pass resolves. Empty at every other moment.
  Set<Card> get passed => const {};

  /// Whether the Auto switch is up: nothing the player still holds can
  /// change how the hand comes out (engine, autopilot.dart). Once up,
  /// up until the hand ends or a single card is left.
  bool get autoOffered => false;

  /// Whether the table plays the player's turns for them, the rest of
  /// this hand. Off at the start of every hand.
  bool get autoPlay => false;

  /// The player's own switch. On, and their turn is played at once.
  void setAutoPlay(bool on) {}

  /// The reaction showing beside [seat]'s badge (packages/table,
  /// reactions.dart), for a moment after its player sent it; null at
  /// every other moment, and always at a solo table, where bots do not
  /// react.
  SeatReaction? reactionAt(int seat) => null;

  /// [seat]'s name as a sentence says it, without a rating beside it:
  /// "Bonnie: Nice".
  String nameAlone(int seat) => names[seat];

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

/// The Auto switch's state, kept by whichever controller drives a
/// table (game_controller.dart, live_controller.dart): whether it has
/// been offered this hand, and whether it is on.
///
/// The judgement is the engine's, over what the screen shows; this
/// keeps it once given. Every reason it can give holds for the rest of
/// the hand in principle, but the screen that showed it does not stay:
/// the trick a player showed out of is swept, a run with a card gone
/// from its middle no longer looks like one. A switch that came and
/// went with them would be a switch nobody could rely on.
class AutoPilot {
  int _hand = -1;
  bool _settled = false;
  bool _on = false;

  /// Whether the switch has been up this hand. It comes with two cards
  /// or more, and then stays: the player turns it on and off as they
  /// like, down to the last card, rather than watch it go from under
  /// their finger as it plays.
  bool _shown = false;

  /// Called on every change the table shows: takes the judgement while
  /// the hand is in play, and starts over when a new one is dealt.
  void watch(TableModel table) {
    final game = table.game;
    if (game.handNumber != _hand) reset(game.handNumber);
    if (_settled && game.phase == Phase.playing && table.handShown.length >= 2) _shown = true;
    if (_settled || game.phase != Phase.playing || !game.knowsHand(table.mySeat)) return;
    final pending = game.pendingTrick;
    // Leading or following is only known on the player's own turn, with
    // the card they are about to play still in their hand.
    final toPlay = pending == null && game.currentSeat == table.mySeat && table.pendingPlay == null;
    _settled = whyHandPlaysItself(
          hand: table.handShown,
          trick: game.trick,
          toPlay: toPlay,
          seat: table.mySeat,
          lastTrick: pending?.plays ?? game.lastTrick,
          // What the badges say each seat has taken, and the trick on its
          // way to its taker: the felt says who, and how many.
          pointsTaken: game.taken.fold(0, (a, b) => a + b) + (pending == null ? 0 : pointsIn(pending.plays.map((p) => p.card))),
        ) !=
        null;
    if (_settled && table.handShown.length >= 2) _shown = true;
  }

  /// A new hand, or a new game: the switch is down and off.
  void reset([int hand = -1]) {
    _hand = hand;
    _settled = false;
    _on = false;
    _shown = false;
  }

  /// Whether the switch is up: offered this hand and in play, with a
  /// card still to play. It first comes with two or more — with one
  /// there is nothing to save — and once up stays to the hand's end.
  bool offered(TableModel table) => _shown && table.game.phase == Phase.playing && table.handShown.isNotEmpty;

  /// Whether it is on.
  bool get on => _on;

  /// The player's switch. Only turned on where it is offered.
  void set(TableModel table, bool on) {
    if (on && !offered(table)) return;
    _on = on;
  }

  /// The card to play for the player now, if the table is to play it:
  /// on, and their turn. The rightmost legal card as the hand is drawn.
  Card? cardFor(TableModel table) {
    if (!_on || !_settled || !table.awaitingPlay) return null;
    final legal = table.legalNow;
    if (legal.isEmpty) return null;
    return autoPlayCard(table.handShown, legal);
  }
}
