/// The player's hand: an overlapping fan sized to whatever width it gets.
///
/// Thirteen cards do not fit side by side on a phone, so they overlap and
/// each card offers a sliver to tap. Two things make the sliver usable:
/// suits are separated by a visible gap, and any card that is playable
/// (or picked for the pass) lifts, so the row reads as "these ones".
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart' as engine;
import 'card_view.dart';

/// Extra space between two suits in the fan. Grouping is most of what
/// makes a 13-card row scannable.
const _suitGap = 11.0;

/// How high a card rises when it is selected or playable.
const _lift = 13.0;

class HandFan extends StatelessWidget {
  const HandFan({
    super.key,
    required this.hand,
    required this.onTap,
    this.playable = const {},
    this.selected = const {},
    this.dimUnplayable = false,
    this.forced,
    this.justReceived = const {},
  });

  /// Sorted; the fan draws it in the order given.
  final List<engine.Card> hand;

  final ValueChanged<engine.Card> onTap;

  /// Cards that can be played (or picked) right now.
  final Set<engine.Card> playable;

  /// Cards chosen for the pass.
  final Set<engine.Card> selected;

  /// Grey everything outside [playable]. False while nothing is being
  /// asked of the player, so the hand does not flash grey between turns.
  final bool dimUnplayable;

  /// The single card the rules leave — ringed, because being forced is
  /// worth seeing rather than discovering.
  final engine.Card? forced;

  /// Cards that arrived in the pass. Dotted for the first trick, so the
  /// three new cards are findable in a hand you have already read once.
  final Set<engine.Card> justReceived;

  @override
  Widget build(BuildContext context) {
    if (hand.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final n = hand.length;
        final gaps = _suitGaps(hand);
        final available = constraints.maxWidth - gaps * _suitGap;

        // Cards are as large as the row allows, capped so a short hand
        // does not turn into playing-card billboards.
        var width = constraints.maxHeight > 0
            ? (constraints.maxHeight - _lift - 6) * cardAspect
            : 62.0;
        width = width.clamp(40.0, 76.0);
        // Then shrunk if even at full overlap the row would spill.
        final maxStep = width * 0.64;
        var step = n > 1 ? (available - width) / (n - 1) : 0.0;
        if (step > maxStep) step = maxStep;
        if (step < width * 0.22) {
          // Too tight even overlapped: give the cards back some width by
          // shrinking them instead of letting the row overflow.
          final fitted = n > 1
              ? available / (1 + (n - 1) * 0.30)
              : available;
          width = fitted.clamp(30.0, width);
          step = width * 0.30;
        }

        final height = cardHeightFor(width) + _lift;
        final rowWidth = width + step * (n - 1) + gaps * _suitGap;
        final left0 = ((constraints.maxWidth - rowWidth) / 2).clamp(0.0, 1e6);

        var x = left0;
        final children = <Widget>[];
        for (var i = 0; i < n; i++) {
          final card = hand[i];
          if (i > 0 && card.suit != hand[i - 1].suit) x += _suitGap;
          final isSelected = selected.contains(card);
          final isPlayable = playable.contains(card);
          final raised = isSelected || (dimUnplayable && isPlayable);
          children.add(Positioned(
            left: x,
            bottom: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(0, raised ? -_lift : 0, 0),
              // One semantics node per card — its name, and the tap —
              // so a screen reader, and the end-to-end suite, can play
              // it by name.
              child: MergeSemantics(
                child: Semantics(
                  button: true,
                  label: card.spoken,
                  selected: isSelected,
                  enabled: !dimUnplayable || isPlayable,
                  onTap: () => onTap(card),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onTap(card),
                    child: ExcludeSemantics(
                      child: CardView(
                        card: card,
                        width: width,
                        dimmed: dimUnplayable && !isPlayable,
                        selected: isSelected,
                        highlighted: card == forced,
                        marked: justReceived.contains(card),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ));
          x += step;
        }

        return SizedBox(
          height: height,
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }

  /// Number of suit boundaries in a sorted hand.
  int _suitGaps(List<engine.Card> hand) {
    var n = 0;
    for (var i = 1; i < hand.length; i++) {
      if (hand[i].suit != hand[i - 1].suit) n++;
    }
    return n;
  }
}
