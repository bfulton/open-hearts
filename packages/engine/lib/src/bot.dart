/// The computer opponents.
///
/// A heuristic player, not a search: every decision is a named rule you
/// can read, argue with, and unit-test. That is the point for now — a
/// bot whose mistakes are legible is worth more during development than
/// a stronger one whose mistakes are not. The interface is deliberately
/// narrow ([choosePass] and [chooseCard] over a [BotView]) so a search
/// player can replace the body later without touching the game or the UI.
///
/// What it knows is exactly what a seated human knows: its own hand, the
/// cards on the table, and which cards have already been played. It does
/// not read other hands.
///
/// A [Persona] sets its temperament: the same rules, with a few of the
/// thresholds and preferences moved. persona.dart has the roster.
library;

import 'dart:math';

import 'card.dart';
import 'persona.dart';
import 'rules.dart';

/// The public information a bot decides from.
class BotView {
  BotView({
    required this.seat,
    required this.hand,
    required this.trick,
    required this.played,
    required this.heartsBroken,
    required this.isFirstTrick,
    this.taken = const [0, 0, 0, 0],
  });

  final int seat;
  final List<Card> hand;

  /// Cards already on the table this trick, in play order.
  final List<Play> trick;

  /// Every card played to a completed trick this hand, the current trick
  /// included. Used to know whether the queen is still out.
  final Set<Card> played;

  final bool heartsBroken;
  final bool isFirstTrick;

  /// Points each seat has taken so far this hand. Public at a real
  /// table — the tricks are face up in front of people.
  final List<int> taken;

  /// True once the queen has been seen, so spades are no longer scary.
  bool get queenGone => played.contains(queenOfSpades);

  /// An opponent who holds every point played so far, far enough along
  /// that letting the rest through would hand them the moon.
  ///
  /// The moon is the one situation where the whole game inverts: taking
  /// points becomes the cheap move and ducking becomes the ruinous one.
  /// Four points is the usual trigger — early enough to break a run
  /// before it is out of reach, late enough not to fire on a single
  /// stray heart. [Persona.moonDefenseTrigger] moves it.
  int? get moonThreat => moonThreatAt(4);

  int? moonThreatAt(int trigger) {
    final total = taken.fold(0, (a, b) => a + b);
    if (total < trigger) return null;
    final holder = taken.indexOf(total);
    if (holder < 0 || holder == seat) return null;
    return holder;
  }

  List<Card> suit(Suit s) => hand.where((c) => c.suit == s).toList();

  int count(Suit s) => hand.where((c) => c.suit == s).length;
}

/// A heuristic Hearts player. Stateless apart from its tie-breaking
/// [Random], so one instance can serve every seat that shares a persona.
class Bot {
  Bot({this.persona = Persona.westley, Random? random})
      : _random = random ?? Random();

  final Persona persona;
  final Random _random;

  int? _moonThreat(BotView view) =>
      view.moonThreatAt(persona.moonDefenseTrigger);

  // ---- passing --------------------------------------------------------

  /// Picks the three cards to pass.
  ///
  /// Two ideas, in priority order:
  ///
  ///  1. **Shed the spade problem.** The queen, and the ace and king above
  ///     her, are only safe behind enough small spades to duck with. With
  ///     a short spade holding they are the first cards out of the hand.
  ///  2. **Then shed height.** Among what is left, the highest cards go —
  ///     hearts weighted up, because a high heart bleeds a point at a time
  ///     all hand long, and low cards in a suit are the cheapest thing to
  ///     own.
  ///
  /// Voiding a suit outright is strong but costs two or three of the
  /// three slots, so it is taken only when it falls out of the ranking
  /// for free.
  List<Card> choosePass(List<Card> hand) {
    final scored = [
      for (final c in hand) (card: c, danger: _passDanger(c, hand)),
    ]..sort((a, b) {
        final d = b.danger.compareTo(a.danger);
        return d != 0 ? d : a.card.compareTo(b.card);
      });
    return [for (final s in scored.take(passSize)) s.card];
  }

  /// How much a card wants to leave the hand. Higher is more urgent.
  /// Whole numbers throughout, so the circuit can carry them.
  int _passDanger(Card card, List<Card> hand) {
    final spades = hand.where((c) => c.suit == Suit.spades).length;
    // Below the queen, spades are the protection; with enough of them
    // you can duck the queen out of someone else's hand. How many is
    // enough, and how much she is then worth keeping, is temperament.
    final spadesProtected = spades >= persona.queenProtectedAt;
    final belowQueen =
        hand.where((c) => c.suit == Suit.spades && c.rank.value < 12).length;
    final highSpadesCovered = belowQueen >= persona.highSpadesCoveredAt;

    switch (card.suit) {
      case Suit.spades:
        if (card == queenOfSpades) {
          return spadesProtected ? persona.queenKeptDanger : 100;
        }
        if (card.rank.value > 12) {
          // A♠/K♠ take the queen when she is led at them. Enough small
          // spades to get under her first makes them survivable.
          return highSpadesCovered ? 45 : 90;
        }
        // Small spades are the protection; passing them is actively bad.
        return -10 + card.rank.value;
      case Suit.hearts:
        // Hearts cost a point every time one lands, and high ones land.
        return card.rank.value * 2 + (card.rank.value >= 12 ? 12 : 0);
      case Suit.clubs:
      case Suit.diamonds:
        final length = hand.where((c) => c.suit == card.suit).length;
        // A high card in a short suit is doubly awkward: it takes tricks
        // AND there is nothing to hide behind. Shedding it also moves the
        // suit toward a void worth having — which a void-maker weights
        // enough that the whole short suit goes.
        return card.rank.value +
            (length <= 3 ? (4 - length) * persona.shortSuitWeight : 0);
    }
  }

  // ---- playing --------------------------------------------------------

  /// Picks a card to play. [legal] is the engine's answer to what is
  /// allowed, so this only ever chooses among lawful cards.
  Card chooseCard(BotView view, List<Card> legal) {
    assert(legal.isNotEmpty);
    if (legal.length == 1) return legal.first;
    if (view.trick.isEmpty) return _lead(view, legal);
    final following = legal.first.suit == view.trick.first.card.suit;
    return following ? _follow(view, legal) : _discard(view, legal);
  }

  /// On lead.
  ///
  /// The first job is to make someone else take the queen. Holding no
  /// spade above her, leading small spades drags her out of whoever does
  /// hold her — the standard "flush the queen" line; how many small
  /// spades it takes to try is [Persona.flushMinSmallSpades]. Otherwise
  /// lead the lowest card of the shortest suit, which both keeps the
  /// trick cheap and works toward the void that makes discarding
  /// possible — or of the longest, whose low cards are the safest leads
  /// in the hand ([Persona.leadFrom]).
  Card _lead(BotView view, List<Card> legal) {
    if (!view.queenGone) {
      final spades = legal.where((c) => c.suit == Suit.spades).toList();
      final holdsHighSpade =
          view.hand.any((c) => c.suit == Suit.spades && c.rank.value >= 12);
      if (spades.length >= persona.flushMinSmallSpades && !holdsHighSpade) {
        return _lowest(spades);
      }
    }
    // Hearts last, since leading them hands out points on purpose.
    final bySuit = <Suit, List<Card>>{};
    for (final c in legal) {
      bySuit.putIfAbsent(c.suit, () => []).add(c);
    }
    List<Suit> ordered({required bool longest}) => bySuit.keys.toList()
      ..sort((a, b) {
        if ((a == Suit.hearts) != (b == Suit.hearts)) {
          return a == Suit.hearts ? 1 : -1;
        }
        final d = bySuit[a]!.length.compareTo(bySuit[b]!.length);
        if (d != 0) return longest ? -d : d;
        return a.index.compareTo(b.index);
      });
    if (persona.leadFrom == LeadFrom.longestWhileLow) {
      final long = ordered(longest: true).first;
      final low = _lowest(bySuit[long]!);
      if (long != Suit.hearts && low.rank.value <= lowLeadRank) return low;
    }
    return _lowest(bySuit[ordered(longest: false).first]!);
  }

  /// A lead this low from a long suit is not going to win the trick.
  static const lowLeadRank = 6;

  /// Following suit.
  ///
  /// Ducking is almost always right, and ducking *as high as possible* is
  /// what makes it pay: the trick still goes elsewhere, but a big card
  /// leaves the hand while it is safe to lose it.
  ///
  /// When nothing ducks, the choice turns on seat. Last to play, the
  /// trick is already yours, so throw the biggest card in the suit and be
  /// rid of it. Otherwise win as cheaply as possible and leave the players
  /// behind you room to take it instead.
  Card _follow(BotView view, List<Card> legal) {
    final led = view.trick.first.card.suit;
    final high = view.trick
        .where((p) => p.card.suit == led)
        .map((p) => p.card.rank.value)
        .reduce(max);

    // With the moon live, ducking is the losing move: one point taken
    // here costs one, and letting the run finish costs twenty-six. Win
    // as cheaply as the suit allows.
    if (_moonThreat(view) != null) {
      final over = legal.where((c) => c.rank.value > high).toList();
      if (over.isNotEmpty) return _lowest(over);
    }

    final under = legal.where((c) => c.rank.value < high).toList();
    if (under.isNotEmpty) {
      // The queen is the exception to "duck high": sliding her under a
      // trick someone else takes is the best thing that can happen to
      // this hand, so she goes ahead of any other duck.
      if (under.contains(queenOfSpades)) return queenOfSpades;
      return _highest(under);
    }

    // Taking the trick is now certain (last seat) or likely.
    final isLastSeat = view.trick.length == seatCountInTrick - 1;
    if (isLastSeat) {
      // Except when winning it cheap is what avoids the queen: with the
      // queen still out and spades led, the smallest winner risks least
      // on the tricks still to come.
      if (led == Suit.spades && !view.queenGone) return _lowest(legal);
      return _highest(legal);
    }
    return _lowest(legal);
  }

  /// Void in the led suit — a free throw, and the only chance all hand to
  /// place a card where it costs nothing.
  ///
  /// The queen first, then the cards that would have taken her, then
  /// hearts from the top, then the highest card of the suit worth
  /// shortening.
  Card _discard(BotView view, List<Card> legal) {
    // Void in the led suit and the moon is live: this trick is going to
    // the shooter, so feeding it points is feeding the shot. Throw the
    // most harmless card in hand instead of the most dangerous one.
    if (_moonThreat(view) != null) {
      final safe = legal.where((c) => cardPoints(c) == 0).toList();
      if (safe.isNotEmpty) return _highest(safe);
    }

    if (legal.contains(queenOfSpades)) return queenOfSpades;

    final highSpades =
        legal.where((c) => c.suit == Suit.spades && c.rank.value > 12).toList();
    if (highSpades.isNotEmpty && !view.queenGone) return _highest(highSpades);

    final hearts = legal.where((c) => c.suit == Suit.hearts).toList();
    if (hearts.isNotEmpty) {
      final top = _highest(hearts);
      // A low heart is a worse throw than a high side-suit card: it gives
      // away a point and keeps the dangerous card. Where "low" ends is
      // temperament.
      if (top.rank.value >= persona.heartDumpRank) return top;
    }

    final side = legal
        .where((c) => c.suit != Suit.hearts && c.suit != Suit.spades)
        .toList();
    if (side.isNotEmpty) {
      final byLength = <Suit, int>{};
      for (final c in view.hand) {
        byLength[c.suit] = (byLength[c.suit] ?? 0) + 1;
      }
      side.sort((a, b) {
        final d = byLength[a.suit]!.compareTo(byLength[b.suit]!);
        return d != 0 ? d : b.rank.value.compareTo(a.rank.value);
      });
      return side.first;
    }
    if (hearts.isNotEmpty) return _highest(hearts);
    return _highest(legal);
  }

  Card _lowest(List<Card> cards) =>
      cards.reduce((a, b) => a.rank.value <= b.rank.value ? a : b);

  Card _highest(List<Card> cards) =>
      cards.reduce((a, b) => a.rank.value >= b.rank.value ? a : b);

  /// Unused today, kept so the tie-break has somewhere to go when the
  /// heuristics are extended.
  // ignore: unused_element
  T _anyOf<T>(List<T> options) => options[_random.nextInt(options.length)];
}

/// A trick is four cards. Named here so [Bot] does not import the game
/// just to know it.
const seatCountInTrick = 4;
