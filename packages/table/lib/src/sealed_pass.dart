/// A pass into a seat whose hand is about to be seen.
///
/// A person's pass to another person is sealed to the receiver, and
/// the engine takes it as unknown. When the receiver leaves before
/// the swap resolves, its hand is opened from escrow for a bot to
/// play — and the engine will not see a hand while a pass into it is
/// unknown, since a seen hand takes what came in. The deal can open
/// that pass now, with the receiver's secret: its positions, and the
/// tokens the passer sealed to the receiver.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

/// Fills in the pass into [seat] from a hidden hand, taken as unknown,
/// now that the deal can open it here. True when nothing stands in the
/// way of seeing [seat]'s hand: no such pass yet, or its cards opened.
/// False while the pass is sealed to a secret this side does not hold
/// — or, from a passer who sealed garbage, for good (docs/03).
bool openPassInto(DealSession d, HeartsGame game, int seat) {
  if (game.phase != Phase.passing) return true;
  final from = (seat - game.passDirection.seatOffset) % seatCount;
  if (from == seat || !game.hasPassed(from) || game.passOf(from) != null) return true;
  final handSize = deckSize ~/ seatCount;
  final cards = <Card>[];
  for (var p = from * handSize; p < (from + 1) * handSize; p++) {
    if (d.holderOf(p) != seat) continue;
    final c = d.openedCardAt(p);
    if (c == null) return false;
    cards.add(Card.deck[c]);
  }
  if (cards.length != passSize) return false;
  game.amendPass(from, cards);
  return true;
}
