/// A kept game as its check replayed it, for looking at afterwards
/// (app: review_page.dart): hand by hand, what each seat was dealt, every
/// card in the order played, and the scores. Filled by either verifier:
/// a game played since the referee's (record.dart), or one kept before
/// (legacy/v2_record.dart).
library;

import 'dart:math' show min;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

/// A game as the verifier replayed it, for looking at afterwards: hand
/// by hand, what each seat was dealt and held after the pass, every
/// card in the order played, and the scores. Filled only as far as the
/// record checks out — a record that fails has no replay worth showing.
class TableReplay {
  TableReplay({this.onHand});

  final List<TableReplayHand> hands = [];

  /// Called as each hand's check is done — and again for the last hand
  /// once the game's closing audit opens its cards — so a game can be
  /// shown a hand at a time while the rest is still being checked.
  final void Function(TableReplayHand hand)? onHand;

  TableReplayHand _hand(int number) {
    while (hands.length <= number) {
      hands.add(TableReplayHand._(hands.length));
    }
    return hands[number];
  }

  /// [card], played by [seat] in [hand]: for the verifiers.
  void played(int hand, int seat, Card card) => _hand(hand).plays.add((seat: seat, card: card));

  /// [game]'s hand over, its scores and, from [deal], the cards as
  /// dealt: for the verifiers.
  void ended(HeartsGame game, [DealSession? deal]) {
    final h = _hand(game.handNumber)
      ..scores = List.of(game.handScores)
      ..totals = List.of(game.totals);
    if (deal != null) {
      List<Card>? cards(List<int>? indices) => indices == null ? null : ([for (final i in indices) Card.deck[i]]..sort());
      final dealt = [for (var s = 0; s < seatCount; s++) cards(deal.dealtHandOf(s))];
      if (dealt.every((c) => c != null)) h.dealt = [for (final c in dealt) c!];
    }
    onHand?.call(h);
  }
}

class TableReplayHand {
  TableReplayHand._(this.number);

  /// As [toJson] wrote it: cards by their index in the deck.
  factory TableReplayHand.fromJson(Map<String, Object?> json) {
    List<Card> cards(Object? l) => [for (final i in l as List) Card.deck[i as int]];
    final h = TableReplayHand._(json['number'] as int)
      ..scores = [for (final x in json['scores'] as List) x as int]
      ..totals = [for (final x in json['totals'] as List) x as int];
    final dealt = json['dealt'];
    if (dealt != null) h.dealt = [for (final d in dealt as List) cards(d)];
    for (final p in json['plays'] as List) {
      final pair = p as List;
      h.plays.add((seat: pair[0] as int, card: Card.deck[pair[1] as int]));
    }
    return h;
  }

  Map<String, Object?> toJson() => {
        'number': number,
        'dealt': dealt == null ? null : [for (final d in dealt!) [for (final c in d) c.index]],
        'plays': [for (final p in plays) [p.seat, p.card.index]],
        'scores': scores,
        'totals': totals,
      };

  final int number;

  /// Each seat's thirteen as dealt; null where the deal never opened
  /// them (a game that ended mid-hand).
  List<List<Card>>? dealt;

  /// Each seat's thirteen once the pass was made: what it played, since
  /// a hand is played out to the last card. Null for a hand cut short.
  List<List<Card>>? get held => plays.length < seatCount * 13
      ? null
      : [
          for (var s = 0; s < seatCount; s++) [for (final p in plays) if (p.seat == s) p.card]..sort(),
        ];

  /// Every card in the order it was played.
  final List<({int seat, Card card})> plays = [];

  /// The hand's points per seat, and the running totals after it; empty
  /// for a hand the game ended in the middle of.
  List<int> scores = const [];
  List<int> totals = const [];

  /// The plays, four to a trick.
  List<List<({int seat, Card card})>> get tricks => [
        for (var i = 0; i < plays.length; i += seatCount) plays.sublist(i, min(i + seatCount, plays.length)),
      ];

  /// What [seat] passed: dealt and not held.
  List<Card> passedBy(int seat) {
    final held = this.held;
    return dealt == null || held == null ? const [] : [for (final c in dealt![seat]) if (!held[seat].contains(c)) c];
  }
}
