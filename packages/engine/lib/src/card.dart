/// The 52-card deck, as value types.
///
/// A [Card] is immutable and interned by its 0..51 index, so equality is
/// identity-cheap and cards can key a Set without a custom hash.
library;

/// Suits in display order: alternating colors, hearts last because the
/// hand fan reads best with the point suit at the end.
enum Suit {
  clubs('C', '♣'),
  diamonds('D', '♦'),
  spades('S', '♠'),
  hearts('H', '♥');

  const Suit(this.letter, this.glyph);

  /// Single letter used in short notation ("QS", "2C") and in tests.
  final String letter;

  /// The pip character drawn in the UI.
  final String glyph;

  bool get isRed => this == diamonds || this == hearts;
}

/// Ranks carry their trick-taking value directly (2..14); there is no
/// second ordering in Hearts, so [value] is the only comparison key.
enum Rank {
  two(2, '2'),
  three(3, '3'),
  four(4, '4'),
  five(5, '5'),
  six(6, '6'),
  seven(7, '7'),
  eight(8, '8'),
  nine(9, '9'),
  ten(10, '10'),
  jack(11, 'J'),
  queen(12, 'Q'),
  king(13, 'K'),
  ace(14, 'A');

  const Rank(this.value, this.label);

  final int value;
  final String label;

  /// The word, for running text. Numbers stay numerals — "the 2 of
  /// clubs" is how the card is actually named at a table.
  String get spoken => switch (this) {
        jack => 'jack',
        queen => 'queen',
        king => 'king',
        ace => 'ace',
        _ => label,
      };
}

/// A playing card. Construct with [Card.of] or [Card.parse]; both return
/// the interned instance, so `identical(Card.of(s, r), Card.of(s, r))`.
class Card implements Comparable<Card> {
  const Card._(this.suit, this.rank);

  final Suit suit;
  final Rank rank;

  /// Stable 0..51 index: suit-major, rank ascending within a suit.
  int get index => suit.index * 13 + (rank.index);

  static final List<Card> _all = List.unmodifiable([
    for (final s in Suit.values)
      for (final r in Rank.values) Card._(s, r),
  ]);

  /// Every card, in index order. Shared and unmodifiable.
  static List<Card> get deck => _all;

  factory Card.of(Suit suit, Rank rank) => _all[suit.index * 13 + rank.index];

  /// Parses short notation: rank label then suit letter, e.g. "QS", "10H",
  /// "2C". Case-insensitive. Throws [FormatException] on anything else.
  factory Card.parse(String text) {
    final s = text.trim().toUpperCase();
    if (s.length < 2) throw FormatException('not a card: "$text"');
    final suit = Suit.values.where((x) => x.letter == s[s.length - 1]);
    if (suit.isEmpty) throw FormatException('not a suit: "$text"');
    final label = s.substring(0, s.length - 1);
    final rank = Rank.values.where((x) => x.label == label);
    if (rank.isEmpty) throw FormatException('not a rank: "$text"');
    return Card.of(suit.first, rank.first);
  }

  /// Short notation, the inverse of [Card.parse].
  String get code => '${rank.label}${suit.letter}';

  /// Pip notation, e.g. "Q♠". Fine for logs and tests; the UI draws its
  /// pips instead (see ui/pip.dart), because ♠♥♦♣ are not in the bundled
  /// font.
  String get label => '${rank.label}${suit.glyph}';

  /// How the card is said out loud: "the queen of spades", "the 2 of
  /// clubs". What the table tells you when it turns a play down.
  String get spoken => '${rank.spoken} of ${suit.name}';

  /// Compares by suit then rank — the hand-fan sort order, NOT trick
  /// strength (only cards of the led suit compare for that, and there
  /// [Rank.value] is the whole story).
  @override
  int compareTo(Card other) => index - other.index;

  @override
  String toString() => code;
}

/// The queen of spades: 13 points on her own, and the axis most Hearts
/// decisions turn on.
final queenOfSpades = Card.of(Suit.spades, Rank.queen);

/// The card that leads the first trick of every hand.
final twoOfClubs = Card.of(Suit.clubs, Rank.two);
