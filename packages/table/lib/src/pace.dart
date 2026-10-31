/// How long somebody takes over a card, and who that puts them with.
///
/// A rating says how well you play and a pace says how fast. They are
/// different questions and a table wants both to match: three people
/// playing a card a second with a fourth who reads the whole hand each
/// turn is a bad evening for all four, whatever anybody is rated.
///
/// **A pace is a device's own account of itself**, and that is not a
/// shortcut. Everything else a table agrees on is derived from the
/// record, which carries no clock at all: an event is `(table, author,
/// kind, body)` and nothing in it says when. The time bank works
/// because each peer measures for itself and a majority has to agree,
/// not because the number is shared — `bankLeftMs` is explicitly "by
/// this peer's clock". So four peers asked how long a seat took would
/// sign four different numbers, and a result needs a majority of
/// identical ones to stand. A pace cannot go in there.
///
/// What a device can measure without dispute is its own turns: the
/// clock it started when the turn opened and stopped when it played.
/// That is exact, it is nobody else's business, and it is the number
/// matchmaking actually needs — to put slow players together, each
/// player has to know their own pace and ask for a table that suits
/// it. So it is stated in the pool the way a rating is stated there,
/// and it decides who you sit with and nothing else.
///
/// A player who lies is matched with people who play at a speed they
/// do not, which is its own punishment and costs nobody else a game.
library;

/// A player's pace: seconds a card, over the cards it was measured on.
class Pace {
  const Pace({this.secondsPerCard = 0, this.cards = 0});

  /// Nothing measured yet.
  static const fresh = Pace();

  /// Seconds this player takes over a card, from turn open to card
  /// played. Zero until [known].
  final double secondsPerCard;

  /// How many of their own cards it is measured over.
  final int cards;

  /// Two hands' worth: enough that one long think about one hand does
  /// not become somebody's pace for ever.
  static const enough = 26;

  /// How far back it looks. A player who has got faster should be able
  /// to say so within an evening, so the mean is over the last few
  /// hundred cards rather than over a lifetime.
  static const remembers = 260;

  /// Whether there is enough behind it to state.
  bool get known => cards >= enough;

  /// What goes in a heartbeat: whole seconds, and zero for unknown —
  /// which reads as "sit me with anybody", and is what a new player is.
  int get stated => known ? secondsPerCard.round().clamp(1, 120) : 0;

  /// A game's worth folded in: [seconds] spent over [cards] cards, as a
  /// running mean that forgets beyond [remembers].
  Pace plus({required int cards, required double seconds}) {
    if (cards <= 0 || seconds < 0) return this;
    // What is already known counts for at most the room the new cards
    // leave, so the newest game always counts whole and the oldest
    // falls off the end.
    final held = (remembers - cards).clamp(0, this.cards);
    final n = held + cards;
    return Pace(secondsPerCard: (secondsPerCard * held + seconds) / n, cards: n);
  }

  /// The word for it, for a screen. Bands wide enough that nobody is on
  /// a boundary they can feel.
  String get word => switch (stated) {
        0 => 'not yet known',
        <= 4 => 'brisk',
        <= 9 => 'steady',
        <= 20 => 'unhurried',
        _ => 'slow',
      };

  Map<String, Object?> toJson() => {'spc': secondsPerCard, 'cards': cards};

  static Pace parse(Object? json) {
    if (json is! Map) return fresh;
    final spc = json['spc'];
    final cards = json['cards'];
    if (spc is! num || cards is! int || cards < 0) return fresh;
    final n = cards > remembers ? remembers : cards;
    return Pace(secondsPerCard: spc.toDouble().clamp(0, 600), cards: n);
  }

  @override
  String toString() => known ? '${secondsPerCard.toStringAsFixed(1)}s/card over $cards' : 'unknown';
}

/// How far apart two stated paces are, for seating. An unknown pace is
/// no distance from anybody: a new player is seated on their rating
/// alone, and learns their own pace by playing.
int paceApart(int a, int b) => a == 0 || b == 0 ? 0 : (a - b).abs();

/// A person's pace at the table, which the bots keep up with: the middle
/// of [cardMs], the times they took over their last few cards (the
/// slower of two, or the one), so that one quick card is not a pace and
/// a few are; null before their first. A person who plays fast, or has
/// the Auto switch play for them, is quick by it within a card or two.
/// The house paces its bots by the quickest person at a live table
/// (house.dart), and a solo table by its one (app, game_controller.dart).
int? tablePaceOf(List<int> cardMs) {
  if (cardMs.isEmpty) return null;
  final sorted = [...cardMs]..sort();
  return sorted[sorted.length ~/ 2];
}

/// How many of a person's last cards [tablePaceOf] is taken over.
const tablePaceCards = 3;
