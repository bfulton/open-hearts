/// The bot as a boolean circuit.
///
/// When a seat is held by nobody — its player left — the bot that plays
/// it must see that seat's cards, and nobody else may. docs/04-live-play.md
/// runs the bot inside a multi-party computation over the seat's
/// secret-shared hand, which only works if the bot can be written as a
/// circuit: no branching on secret data, no loop over a hand whose
/// contents are unknown. This file is that rewrite. [ObliviousBot] must
/// choose exactly what [Bot] chooses on every input, and the test proves
/// it over thousands of real decisions.
///
/// It is also a measurement. What a garbled circuit costs is its AND
/// gates — XOR and NOT are free (Kolesnikov–Schneider 2008) — so
/// [Circuit] counts them, and tool/circuit_count.dart reports the count.
///
/// Three kinds of value flow through a circuit here:
///
///  - **secret** wires carry the hand. Every AND that touches one costs.
///  - **public** wires carry the table: the trick, whether hearts are
///    broken, who has taken what. Both parties know them, so anything
///    computed from public wires alone is done in the clear for free
///    and enters the circuit as an input. An AND between a public wire
///    and a secret one is still a real gate: the circuit is built before
///    the table state is known, so the gate has to exist.
///  - **constants** are the structure — "this index is a heart". They
///    fold away entirely.
///
/// Values are simulated as the circuit is built, so the same code that
/// counts gates also computes the answer to check against the bot.
library;

import 'bot.dart';
import 'card.dart';
import 'rules.dart';

/// What a wire is known to be: a compile-time constant, a value both
/// parties know, or a value neither may learn.
enum Taint { constant, public, secret }

/// One wire of a circuit, with its simulated value.
class Bit {
  const Bit._(this.value, this.taint);

  final bool value;
  final Taint taint;

  bool get isConstant => taint == Taint.constant;
  bool get isSecret => taint == Taint.secret;

  @override
  String toString() => '${value ? 1 : 0}${taint.name[0]}';
}

/// Builds gates, folds constants, and counts the ANDs that cost.
///
/// With [foldPublic] the public inputs are treated as constants: that is
/// the cost of a circuit built *after* the table state is known, a lower
/// bound the precomputed circuit cannot reach.
class Circuit {
  Circuit({this.foldPublic = false});

  final bool foldPublic;

  /// AND gates with at least one secret operand.
  int ands = 0;

  int secretInputs = 0;
  int publicInputs = 0;

  static const zero = Bit._(false, Taint.constant);
  static const one = Bit._(true, Taint.constant);

  Bit constant(bool v) => v ? one : zero;

  Bit secret(bool v) {
    secretInputs++;
    return Bit._(v, Taint.secret);
  }

  Bit public(bool v) {
    if (foldPublic) return constant(v);
    publicInputs++;
    return Bit._(v, Taint.public);
  }

  // ---- gates ----------------------------------------------------------

  Bit and(Bit a, Bit b) {
    if (a.isConstant) return a.value ? b : zero;
    if (b.isConstant) return b.value ? a : zero;
    if (a.isSecret || b.isSecret) {
      ands++;
      return Bit._(a.value && b.value, Taint.secret);
    }
    return Bit._(a.value && b.value, Taint.public);
  }

  Bit not(Bit a) =>
      a.isConstant ? constant(!a.value) : Bit._(!a.value, a.taint);

  Bit xor(Bit a, Bit b) {
    if (a.isConstant) return a.value ? not(b) : b;
    if (b.isConstant) return b.value ? not(a) : a;
    final taint = a.isSecret || b.isSecret ? Taint.secret : Taint.public;
    return Bit._(a.value ^ b.value, taint);
  }

  Bit or(Bit a, Bit b) => not(and(not(a), not(b)));

  /// `sel ? ifTrue : ifFalse`, one AND.
  Bit mux(Bit sel, Bit ifTrue, Bit ifFalse) =>
      xor(ifFalse, and(sel, xor(ifTrue, ifFalse)));

  /// OR of many: n−1 ANDs.
  Bit any(Iterable<Bit> bits) => bits.fold(zero, or);

  /// AND of many: n−1 ANDs.
  Bit all(Iterable<Bit> bits) => bits.fold(one, and);

  /// XOR of many: free. Equal to OR when at most one bit is set.
  Bit parity(Iterable<Bit> bits) => bits.fold(zero, xor);

  // ---- vectors --------------------------------------------------------

  List<Bit> andEach(List<Bit> v, Bit b) => [for (final x in v) and(x, b)];

  List<Bit> muxEach(Bit sel, List<Bit> ifTrue, List<Bit> ifFalse) => [
        for (var i = 0; i < ifTrue.length; i++) mux(sel, ifTrue[i], ifFalse[i]),
      ];

  List<Bit> xorEach(List<Bit> a, List<Bit> b) =>
      [for (var i = 0; i < a.length; i++) xor(a[i], b[i])];

  /// One-hot of the first set bit: n−1 ANDs.
  ///
  /// `seen` after position i is the OR of everything up to i, but since
  /// out[i] is exactly the bit that turns it on, seen ⊕= out[i] — free.
  List<Bit> firstSet(List<Bit> v) {
    var seen = zero;
    final out = <Bit>[];
    for (final b in v) {
      final o = and(b, not(seen));
      out.add(o);
      seen = xor(seen, o);
    }
    return out;
  }

  /// One-hot of the last set bit: n−1 ANDs.
  List<Bit> lastSet(List<Bit> v) =>
      firstSet(v.reversed.toList()).reversed.toList();

  /// Little-endian count of set bits. Full and half adders cost one AND
  /// each with free XOR, so n bits cost about n − popcount(n).
  List<Bit> popcount(List<Bit> bits, {int width = 6}) {
    final columns = <List<Bit>>[List.of(bits)];
    final out = <Bit>[];
    for (var w = 0; w < columns.length; w++) {
      final col = columns[w];
      List<Bit> carries() {
        if (columns.length == w + 1) columns.add([]);
        return columns[w + 1];
      }

      while (col.length > 1) {
        if (col.length >= 3) {
          final a = col.removeLast();
          final b = col.removeLast();
          final c = col.removeLast();
          final ab = xor(a, b);
          col.add(xor(ab, c));
          carries().add(xor(and(ab, xor(a, c)), a)); // majority
        } else {
          final a = col.removeLast();
          final b = col.removeLast();
          col.add(xor(a, b));
          carries().add(and(a, b));
        }
      }
      out.add(col.isEmpty ? zero : col.single);
    }
    while (out.length < width) {
      out.add(zero);
    }
    assert(out.length == width, 'popcount overflowed $width bits');
    return out;
  }

  /// Little-endian constant.
  List<Bit> number(int n, int width) =>
      [for (var k = 0; k < width; k++) constant((n >> k) & 1 == 1)];

  /// `a < b` for little-endian unsigned values: the final borrow of
  /// a − b, one AND per bit.
  Bit lt(List<Bit> a, List<Bit> b) {
    final width = a.length > b.length ? a.length : b.length;
    var borrow = zero;
    for (var k = 0; k < width; k++) {
      final ak = k < a.length ? a[k] : zero;
      final bk = k < b.length ? b[k] : zero;
      borrow = mux(xor(ak, bk), bk, borrow);
    }
    return borrow;
  }

  Bit eq(List<Bit> a, List<Bit> b) => not(any(xorEach(a, b)));

  Bit isZero(List<Bit> a) => not(any(a));
}

/// The bot's inputs that everyone at the table can see, as wires.
///
/// Built from a [BotView] so the circuit and the bot read the same
/// state, but reduced to what the policy actually consumes: the whole
/// `played` set collapses to one bit (is the queen gone), the trick to
/// its led suit, its top rank, and whether this is the last seat.
class PublicPlay {
  PublicPlay(Circuit c, BotView view)
      : isLead = c.public(view.trick.isEmpty),
        isFirstTrick = c.public(view.isFirstTrick),
        heartsBroken = c.public(view.heartsBroken),
        isLastSeat = c.public(view.trick.length == seatCountInTrick - 1),
        queenGone = c.public(view.queenGone),
        moonThreat = c.public(view.moonThreat != null),
        ledSuit = [
          for (final s in Suit.values)
            c.public(view.trick.isNotEmpty && view.trick.first.card.suit == s),
        ],
        highGeq = [
          for (var r = 0; r < 13; r++) c.public(_topRank(view) >= r + 2),
        ];

  final Bit isLead;
  final Bit isFirstTrick;
  final Bit heartsBroken;
  final Bit isLastSeat;
  final Bit queenGone;
  final Bit moonThreat;

  /// One-hot by [Suit.index]; all clear on lead.
  final List<Bit> ledSuit;

  /// Thermometer code of the top led-suit rank on the table:
  /// `highGeq[k]` is set when that rank is at least k + 2.
  final List<Bit> highGeq;

  static int _topRank(BotView view) {
    if (view.trick.isEmpty) return 0;
    final led = view.trick.first.card.suit;
    var top = 0;
    for (final p in view.trick) {
      if (p.card.suit == led && p.card.rank.value > top) top = p.card.rank.value;
    }
    return top;
  }
}

/// [Bot] with every branch replaced by a mux.
///
/// Every method takes and returns 52-wide vectors indexed by
/// [Card.index] — suit-major, so each suit is a contiguous lane of 13
/// bits in rank order — and the chosen card comes back one-hot.
class ObliviousBot {
  ObliviousBot(this.c);

  final Circuit c;

  static const _lane = 13;
  static const _queen = 10; // rank index of Q (2 is 0)
  static const _king = 11;
  static const _ace = 12;
  static const _ten = 8;

  static int _suitOf(int i) => i ~/ _lane;
  static int _rankOf(int i) => i % _lane;
  static bool _isHeart(int i) => _suitOf(i) == Suit.hearts.index;
  static bool _isPoint(int i) => _isHeart(i) || i == queenOfSpades.index;

  static List<Bit> _laneOf(List<Bit> v, Suit s) =>
      v.sublist(s.index * _lane, s.index * _lane + _lane);

  /// Wires a hand in as 52 secret bits.
  List<Bit> secretHand(Iterable<Card> hand) {
    final held = List.filled(52, false);
    for (final card in hand) {
      held[card.index] = true;
    }
    return [for (final h in held) c.secret(h)];
  }

  /// Reads a one-hot answer back out. Throws if it is not one-hot,
  /// because that is a bug in the circuit, not a legal outcome.
  static Card decode(List<Bit> oneHot) {
    Card? found;
    for (var i = 0; i < 52; i++) {
      if (oneHot[i].value) {
        if (found != null) throw StateError('two cards chosen: $found and ${Card.deck[i]}');
        found = Card.deck[i];
      }
    }
    if (found == null) throw StateError('no card chosen');
    return found;
  }

  static List<Card> decodeSet(List<Bit> v) =>
      [for (var i = 0; i < 52; i++) if (v[i].value) Card.deck[i]];

  // ---- rules ----------------------------------------------------------

  /// [legalPlays], obliviously. Also returns whether the hand can follow
  /// suit, which [chooseCard] needs and which falls out for free.
  ({List<Bit> legal, Bit hasFollowing}) legal(List<Bit> hand, PublicPlay p) {
    // On lead: everything but hearts until they are broken, unless
    // hearts are all that is left; on the first trick, the 2♣ alone.
    final hasNonHearts = c.any([for (var i = 0; i < 52; i++) if (!_isHeart(i)) hand[i]]);
    final restrictLead = c.and(c.not(p.heartsBroken), hasNonHearts);
    final leadLegal = [
      for (var i = 0; i < 52; i++)
        if (i == twoOfClubs.index)
          hand[i]
        else
          c.and(
            c.not(p.isFirstTrick),
            _isHeart(i) ? c.and(hand[i], c.not(restrictLead)) : hand[i],
          ),
    ];

    // Following: the led suit if held, else anything; on the first
    // trick, no points unless points are all that is left.
    final following = [for (var i = 0; i < 52; i++) c.and(hand[i], p.ledSuit[_suitOf(i)])];
    final hasFollowing = c.any(following);
    final candidates = [
      for (var i = 0; i < 52; i++)
        // following[i] when the suit is held; otherwise hand[i], which
        // is hand[i] ⊕ following[i] because following is then all clear.
        c.xor(following[i], c.and(c.xor(hand[i], following[i]), c.not(hasFollowing))),
    ];
    final hasPointless = c.any([for (var i = 0; i < 52; i++) if (!_isPoint(i)) candidates[i]]);
    final restrictFollow = c.and(p.isFirstTrick, hasPointless);
    final followLegal = [
      for (var i = 0; i < 52; i++)
        _isPoint(i) ? c.and(candidates[i], c.not(restrictFollow)) : candidates[i],
    ];

    return (legal: c.muxEach(p.isLead, leadLegal, followLegal), hasFollowing: hasFollowing);
  }

  // ---- playing --------------------------------------------------------

  /// [Bot.chooseCard]. The `legal.length == 1` shortcut needs no gate:
  /// every branch below picks from `legal`, so a single legal card is
  /// what every branch returns.
  List<Bit> chooseCard(List<Bit> hand, PublicPlay p) {
    final r = legal(hand, p);
    final lead = _lead(hand, r.legal, p);
    final follow = _follow(r.legal, p);
    final discard = _discard(r.legal, p);
    return c.muxEach(p.isLead, lead, c.muxEach(r.hasFollowing, follow, discard));
  }

  List<Bit> _lead(List<Bit> hand, List<Bit> legal, PublicPlay p) {
    // Flush the queen: small spades, holding nothing at or above her.
    final spades = _laneOf(legal, Suit.spades);
    final spadeLane = Suit.spades.index * _lane;
    final holdsHighSpade = c.any([hand[spadeLane + _queen], hand[spadeLane + _king], hand[spadeLane + _ace]]);
    final flush = c.all([c.not(p.queenGone), c.any(spades), c.not(holdsHighSpade)]);
    final flushCard = c.firstSet(spades);

    // Otherwise the lowest card of the shortest suit, hearts last, ties
    // to the lower suit index. Empty suits count as 15 so they lose.
    final counts = [for (final s in Suit.values) c.popcount(_laneOf(legal, s), width: 4)];
    final empty = [for (final n in counts) c.isZero(n)];
    final eff = [
      for (var s = 0; s < 3; s++) [for (final b in counts[s]) c.or(b, empty[s])],
    ];
    final clubsLeDiamonds = c.not(c.lt(eff[1], eff[0]));
    final bestOfTwo = c.muxEach(clubsLeDiamonds, eff[0], eff[1]);
    final twoLeSpades = c.not(c.lt(eff[2], bestOfTwo));
    final anyNonHeart = c.not(c.all([empty[0], empty[1], empty[2]]));
    final sel = [
      c.all([clubsLeDiamonds, twoLeSpades, anyNonHeart]),
      c.all([c.not(clubsLeDiamonds), twoLeSpades, anyNonHeart]),
      c.and(c.not(twoLeSpades), anyNonHeart),
      c.not(anyNonHeart),
    ];
    final shortest = [
      for (final s in Suit.values) ...c.andEach(c.firstSet(_laneOf(legal, s)), sel[s.index]),
    ];

    return [
      for (var i = 0; i < 52; i++)
        _suitOf(i) == Suit.spades.index
            ? c.mux(flush, flushCard[_rankOf(i)], shortest[i])
            : c.and(shortest[i], c.not(flush)),
    ];
  }

  List<Bit> _follow(List<Bit> legal, PublicPlay p) {
    // Following, legal lies in one suit, so folding the four lanes with
    // XOR is the same as OR and costs nothing.
    final lane = [
      for (var r = 0; r < _lane; r++) c.parity([for (final s in Suit.values) legal[s.index * _lane + r]]),
    ];
    final under = [for (var r = 0; r < _lane; r++) r == _ace ? Circuit.zero : c.and(lane[r], p.highGeq[r + 1])];
    final over = [for (var r = 0; r < _lane; r++) c.and(lane[r], c.not(p.highGeq[r]))];

    // Moon live: win as cheaply as the suit allows.
    final moonWin = c.and(p.moonThreat, c.any(over));
    final lowestOver = c.firstSet(over);

    // Duck as high as possible; the queen ahead of any other duck.
    final hasUnder = c.any(under);
    final queenUnder = c.and(under[_queen], p.ledSuit[Suit.spades.index]);
    final highestUnder = c.lastSet(under);
    final duck = [
      for (var r = 0; r < _lane; r++)
        r == _queen ? c.or(highestUnder[r], queenUnder) : c.and(highestUnder[r], c.not(queenUnder)),
    ];

    // Taking it: last seat throws the top card, except spades with the
    // queen still out; anyone else wins as cheaply as possible.
    final cheapWin = c.all([p.isLastSeat, p.ledSuit[Suit.spades.index], c.not(p.queenGone)]);
    final takeLow = c.or(c.not(p.isLastSeat), cheapWin);
    final take = c.muxEach(takeLow, c.firstSet(lane), c.lastSet(lane));

    final pick = c.muxEach(moonWin, lowestOver, c.muxEach(hasUnder, duck, take));
    return [for (var i = 0; i < 52; i++) c.and(pick[_rankOf(i)], p.ledSuit[_suitOf(i)])];
  }

  List<Bit> _discard(List<Bit> legal, PublicPlay p) {
    final spadeLane = Suit.spades.index * _lane;

    // 1. Moon live: the highest harmless card. Ties go to the lower suit,
    //    so order by rank ascending then suit descending and take the last.
    final safeOrder = [for (var i = 0; i < 52; i++) if (!_isPoint(i)) i]
      ..sort((a, b) {
        final d = _rankOf(a).compareTo(_rankOf(b));
        return d != 0 ? d : _suitOf(b).compareTo(_suitOf(a));
      });
    final safeTopOrdered = c.lastSet([for (final i in safeOrder) legal[i]]);
    final safeTop = List<Bit>.filled(52, Circuit.zero);
    for (var k = 0; k < safeOrder.length; k++) {
      safeTop[safeOrder[k]] = safeTopOrdered[k];
    }
    final moonSafe = c.and(p.moonThreat, c.any([for (final i in safeOrder) legal[i]]));

    // 2. The queen.
    final hasQueen = legal[queenOfSpades.index];

    // 3. A♠/K♠ while she is still out, the ace first.
    final kingS = legal[spadeLane + _king];
    final aceS = legal[spadeLane + _ace];
    final dumpHigh = c.and(c.or(kingS, aceS), c.not(p.queenGone));
    final kingNotAce = c.and(kingS, c.not(aceS));

    // 4. The top heart if it is a ten or better; 6. any top heart.
    final hearts = _laneOf(legal, Suit.hearts);
    final hasHearts = c.any(hearts);
    final topHeart = c.lastSet(hearts);
    final heartHigh = c.any(hearts.sublist(_ten));

    // 5. The highest card of the shorter side suit; equal lengths
    //    compare across both suits, ties to clubs.
    final clubs = _laneOf(legal, Suit.clubs);
    final diamonds = _laneOf(legal, Suit.diamonds);
    final lenC = c.popcount(clubs, width: 4);
    final lenD = c.popcount(diamonds, width: 4);
    final hasC = c.not(c.isZero(lenC));
    final hasD = c.not(c.isZero(lenD));
    final onlyC = c.and(hasC, c.or(c.not(hasD), c.lt(lenC, lenD)));
    final onlyD = c.and(hasD, c.or(c.not(hasC), c.lt(lenD, lenC)));
    final sideOrder = [
      for (var i = 0; i < 2 * _lane; i++) i
    ]..sort((a, b) {
        final d = _rankOf(a).compareTo(_rankOf(b));
        return d != 0 ? d : _suitOf(b).compareTo(_suitOf(a));
      });
    final side = [...c.andEach(clubs, c.not(onlyD)), ...c.andEach(diamonds, c.not(onlyC))];
    final sideTopOrdered = c.lastSet([for (final i in sideOrder) side[i]]);
    final sideTop = List<Bit>.filled(2 * _lane, Circuit.zero);
    for (var k = 0; k < sideOrder.length; k++) {
      sideTop[sideOrder[k]] = sideTopOrdered[k];
    }
    final hasSide = c.or(hasC, hasD);

    // 7. Whatever is left is spades below the queen (or above her once
    //    she is gone): the highest.
    final spadesTop = c.lastSet(_laneOf(legal, Suit.spades));

    // First rule that applies wins. `taken` is the OR of the rules so
    // far, kept as XOR because each new rule fires only when it is clear.
    Bit taken = moonSafe;
    Bit next(Bit fires) {
      final on = c.and(fires, c.not(taken));
      taken = c.xor(taken, on);
      return on;
    }

    final p1 = moonSafe;
    final p2 = next(hasQueen);
    final p3 = next(dumpHigh);
    final p4 = next(heartHigh);
    final p5 = next(hasSide);
    final p6 = next(hasHearts);
    final p7 = c.not(taken);
    final anyHeart = c.xor(p4, p6);

    // The rules are mutually exclusive, so their one-hots XOR together.
    return [
      for (var i = 0; i < 52; i++)
        c.parity([
          if (!_isPoint(i)) c.and(p1, safeTop[i]),
          if (i == queenOfSpades.index) p2,
          if (i == spadeLane + _ace) c.and(p3, aceS),
          if (i == spadeLane + _king) c.and(p3, kingNotAce),
          if (_isHeart(i)) c.and(anyHeart, topHeart[_rankOf(i)]),
          if (i < 2 * _lane) c.and(p5, sideTop[i]),
          if (_suitOf(i) == Suit.spades.index) c.and(p7, spadesTop[_rankOf(i)]),
        ]),
    ];
  }

  // ---- the seat's cards, as dealt ------------------------------------

  /// [chooseCard] over the hand as the deal actually leaves it: thirteen
  /// positions, each holding a card's 0..51 index, and the answer given
  /// back as the position to open.
  ///
  /// A bot seat's cards are thirteen ciphertexts at known positions; the
  /// survivors can open one position but must not learn which card is
  /// where. So the hand enters as thirteen 6-bit indexes secret-shared
  /// at the deal, the circuit decodes them into the 52-bit set the policy
  /// reads, and the chosen card is matched back to its position.
  ///
  /// [cards] is the seat's hand in position order, all thirteen, played
  /// or not; [held] says publicly which positions are still unopened,
  /// since a play opens its position for everyone to see. The result's
  /// `heldAt` is the 13-bit one-hot position of the card to open.
  ({List<Bit> heldAt, List<Bit> chosen}) chooseCardAt(
    List<List<Bit>> cards,
    List<Bit> held,
    PublicPlay p,
  ) {
    assert(cards.length == 13 && cards.every((c) => c.length == 6));
    assert(held.length == 13);
    final decoded = [
      for (var k = 0; k < 13; k++) _decodeIndex(cards[k], held[k]),
    ];
    // Distinct cards, so the one-hots never overlap and XOR is OR.
    final hand = [
      for (var i = 0; i < 52; i++) c.parity([for (final d in decoded) d[i]]),
    ];
    final chosen = chooseCard(hand, p);
    // One-hot back to six bits is free: each bit is the XOR of the
    // entries whose index has it set.
    final chosenIndex = [
      for (var k = 0; k < 6; k++)
        c.parity([for (var i = 0; i < 52; i++) if ((i >> k) & 1 == 1) chosen[i]]),
    ];
    // An opened position holds a card no longer in hand, so it can never
    // match the choice; no masking needed here.
    return (
      heldAt: [for (final index in cards) c.eq(index, chosenIndex)],
      chosen: chosen,
    );
  }

  /// Six secret bits to a 52-wide one-hot, all clear unless [held]: two
  /// 3-to-8 decoders and a product, about 70 ANDs.
  List<Bit> _decodeIndex(List<Bit> index, Bit held) {
    List<Bit> decode3(List<Bit> b) {
      // 2→4 costs one AND: a∧b, then the other three by XOR.
      final ab = c.and(b[0], b[1]);
      final quad = [
        c.xor(c.xor(c.xor(Circuit.one, b[0]), b[1]), ab), // ¬a∧¬b
        c.xor(b[0], ab), // a∧¬b
        c.xor(b[1], ab), // ¬a∧b
        ab,
      ];
      return [
        for (final q in quad) c.xor(q, c.and(q, b[2])), // q∧¬c
        for (final q in quad) c.and(q, b[2]),
      ];
    }

    final low = decode3(index.sublist(0, 3));
    final high = c.andEach(decode3(index.sublist(3, 6)), held);
    return [for (var i = 0; i < 52; i++) c.and(high[i >> 3], low[i & 7])];
  }

  // ---- passing --------------------------------------------------------

  /// [Bot.choosePass]: the three most dangerous cards, as a 52-bit set.
  ///
  /// Danger is ranked pairwise. For each pair the circuit computes one
  /// `less-than`; the card ahead is the more dangerous one, or on a tie
  /// the lower index, so one bit settles both directions. A card is
  /// passed when fewer than three held cards rank ahead of it.
  List<Bit> choosePass(List<Bit> hand) {
    final danger = _dangers(hand);
    final ahead = List.generate(52, (_) => List<Bit>.filled(52, Circuit.zero));
    for (var i = 0; i < 52; i++) {
      for (var j = i + 1; j < 52; j++) {
        final iLess = c.lt(danger[i], danger[j]);
        ahead[j][i] = iLess; // j ahead of i only by strictly more danger
        ahead[i][j] = c.not(iLess); // i ahead of j on a tie, by index
      }
    }
    return [
      for (var i = 0; i < 52; i++)
        c.and(
          hand[i],
          c.lt(
            c.popcount([for (var j = 0; j < 52; j++) if (j != i) c.and(hand[j], ahead[j][i])]),
            c.number(passSize, 6),
          ),
        ),
    ];
  }

  /// `_passDanger` for every card, as 7-bit values offset by 10 so the
  /// smallest (a 2♠ at −8) is still unsigned. Almost every card's danger
  /// is a constant; the rest select among a few constants on a bit or
  /// two of hand shape, which with free XOR costs nothing beyond the
  /// counts themselves.
  List<List<Bit>> _dangers(List<Bit> hand) {
    const offset = 10;
    const width = 7;
    final spades = _laneOf(hand, Suit.spades);
    final spadesProtected = c.not(c.lt(c.popcount(spades, width: 4), c.number(5, 4)));
    final belowQueenOk = c.not(c.lt(c.popcount(spades.sublist(0, _queen), width: 4), c.number(3, 4)));

    List<Bit> pick(Bit sel, int ifTrue, int ifFalse) =>
        c.muxEach(sel, c.number(ifTrue + offset, width), c.number(ifFalse + offset, width));

    // Short side suits add (4 − length) × 3; four options, one-hot.
    List<List<Bit>> sideDangers(Suit suit) {
      final len = c.popcount(_laneOf(hand, suit), width: 4);
      final is1 = c.eq(len, c.number(1, 4));
      final is2 = c.eq(len, c.number(2, 4));
      final is3 = c.eq(len, c.number(3, 4));
      final longer = c.not(c.any([is1, is2, is3]));
      return [
        for (var r = 0; r < _lane; r++)
          [
            for (var k = 0; k < width; k++)
              c.parity([
                for (final (sel, bonus) in [(is1, 9), (is2, 6), (is3, 3), (longer, 0)])
                  c.and(sel, c.constant(((r + 2 + bonus + offset) >> k) & 1 == 1)),
              ]),
          ],
      ];
    }

    final clubs = sideDangers(Suit.clubs);
    final diamonds = sideDangers(Suit.diamonds);
    return [
      for (var i = 0; i < 52; i++)
        switch (Suit.values[_suitOf(i)]) {
          Suit.clubs => clubs[_rankOf(i)],
          Suit.diamonds => diamonds[_rankOf(i)],
          Suit.spades => _rankOf(i) == _queen
              ? pick(spadesProtected, 60, 100)
              : _rankOf(i) > _queen
                  ? pick(belowQueenOk, 45, 90)
                  : c.number(-10 + _rankOf(i) + 2 + offset, width),
          Suit.hearts => c.number(
              (_rankOf(i) + 2) * 2 + (_rankOf(i) + 2 >= 12 ? 12 : 0) + offset, width),
        },
    ];
  }
}
